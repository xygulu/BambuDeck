import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the vision model decided about one frame. Field names mirror the
/// strict JSON the prompt demands, so [parseVisionVerdict] is a thin,
/// lenient decode.
class VisionVerdict {
  const VisionVerdict({
    required this.platformHasObject,
    required this.printRunning,
    required this.abnormal,
    required this.notes,
  });

  /// The print bed carries a (possibly finished) object.
  final bool platformHasObject;

  /// Material is actively extruding right now.
  final bool printRunning;

  /// none = looks healthy; spaghetti = 炒面 (extrusion in mid-air / pile of
  /// filament); empty = 空打 (no visible object being printed); other.
  final String abnormal;

  final String notes;

  bool get isAbnormal => abnormal != 'none' && abnormal.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'platformHasObject': platformHasObject,
        'printRunning': printRunning,
        'abnormal': abnormal,
        'notes': notes,
      };
}

/// Parses the model's reply into a [VisionVerdict]. Lenient on purpose:
/// models wrap JSON in markdown fences, add prose, or miss fields - a
/// failed parse returns null and the caller treats the frame as
/// inconclusive instead of acting on a guess.
VisionVerdict? parseVisionVerdict(String reply) {
  final json = _extractJson(reply);
  if (json == null) return null;
  Map<String, dynamic> doc;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    doc = decoded;
  } on FormatException {
    return null;
  }
  String abnormal = (doc['abnormal'] ?? doc['abnormality'] ?? 'none')
      .toString()
      .trim()
      .toLowerCase();
  if (abnormal.isEmpty) abnormal = 'none';
  return VisionVerdict(
    platformHasObject: doc['platform_has_object'] == true ||
        doc['platformHasObject'] == true,
    printRunning:
        doc['print_running'] == true || doc['printRunning'] == true,
    abnormal: abnormal,
    notes: (doc['notes'] ?? doc['note'] ?? '').toString(),
  );
}

/// Pulls the first balanced JSON object out of [reply], skipping markdown
/// fences and surrounding prose.
String? _extractJson(String reply) {
  final start = reply.indexOf('{');
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  for (var i = start; i < reply.length; i++) {
    final ch = reply[i];
    if (inString) {
      if (ch == '\\') {
        i++; // skip the escaped character
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return reply.substring(start, i + 1);
    }
  }
  return null;
}

/// The prompt sent with every frame: one dense paragraph demanding strict
/// JSON, bilingual because vision models answer notes in the user's
/// language.
const visionPrompt =
    '这是3D打印机的监控画面。请判断:1) platform_has_object: 打印平台上是否有物体;'
    '2) print_running: 是否正在打印(挤出机在出料、打印头在移动的迹象);'
    '3) abnormal: 异常类型,只能是 "none"(正常)、"spaghetti"(炒面:悬空出料/'
    '大量乱丝缠绕)、"empty"(空打:平台无物体却持续出料)、"other"(其他明显异常);'
    '4) notes: 一句话说明(中文)。只输出JSON,格式:'
    '{"platform_has_object":true,"print_running":true,"abnormal":"none","notes":"…"}';

/// Vision client speaking two protocols, picked from the base URL:
///
/// - **OpenAI** (`{base}/chat/completions`, image_url + data: URI): 智谱
///   GLM-4V, Qwen-VL (DashScope compatible mode), OpenAI, Ollama+llava, vLLM.
/// - **Anthropic Messages** (`{base}/v1/messages`, base64 image block):
///   api.anthropic.com, and the Anthropic-compatible endpoints the Claude
///   Code ecosystem uses - e.g. MiniMax's `https://api.minimaxi.com/anthropic`
///   (M2/M3). A URL whose path contains `anthropic` takes this branch;
///   posting /chat/completions there answers 404 (实测 2026-10-24).
class VisionLlmClient {
  VisionLlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.postOverride,
    this.timeout = const Duration(seconds: 45),
    this.log,
  });

  /// API root INCLUDING /v1-style prefix, e.g.
  /// `https://open.bigmodel.cn/api/paas/v4` (OpenAI shape) or
  /// `https://api.minimaxi.com/anthropic` (Anthropic shape).
  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;

  /// Injectable for tests: performs the JSON POST, returns the decoded
  /// envelope.
  Future<Map<String, dynamic>> Function(Uri uri, Map<String, dynamic> body,
      Map<String, String> headers)? postOverride;

  final void Function(String line)? log;

  void _logLine(String line) => log?.call('[vision] $line');

  /// Analyzes one frame image; returns the raw content string (null on
  /// HTTP or shape failure - the caller decides how inconclusive is
  /// handled). [mimeType] must match the encoded bytes.
  Future<String?> analyzeFrame(Uint8List image,
      {String mimeType = 'image/png'}) async {
    final uri = _uri();
    final body = _body(image, mimeType);
    _logLine('POST $uri model=$model bytes=${image.length}');
    final Map<String, dynamic> doc;
    try {
      doc = await (postOverride != null
          ? postOverride!(uri, body, _headers())
          : _post(uri, body));
    } catch (e) {
      _logLine('request failed: $e');
      return null;
    }
    try {
      if (_anthropic) {
        final content = doc['content'];
        if (content is List) {
          final texts = [
            for (final part in content)
              if (part is Map && part['type'] == 'text' && part['text'] != null)
                part['text'].toString(),
          ];
          if (texts.isNotEmpty) return texts.join('\n');
        }
        _logLine('no text in reply: ${doc.keys.toList()}');
        return null;
      }
      final choices = doc['choices'];
      if (choices is! List || choices.isEmpty) {
        _logLine('no choices in reply: ${doc.keys.toList()}');
        return null;
      }
      final message = choices.first['message'];
      final content = message is Map<String, dynamic>
          ? message['content']
          : choices.first['text'];
      return content?.toString();
    } catch (e) {
      _logLine('reply shape unexpected: $e');
      return null;
    }
  }

  /// Anthropic Messages protocol when the base path says so (see the class
  /// docs). The path is normalized so both `…/anthropic` and
  /// `…/anthropic/v1` end up at `…/v1/messages`.
  bool get _anthropic =>
      (Uri.tryParse(baseUrl)?.path.toLowerCase().contains('anthropic')) ??
      baseUrl.toLowerCase().contains('anthropic');

  Uri _uri() {
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    if (!_anthropic) return Uri.parse('$base/chat/completions');
    return Uri.parse(
        base.endsWith('/v1') ? '$base/messages' : '$base/v1/messages');
  }

  Map<String, dynamic> _body(Uint8List image, String mimeType) {
    final b64 = base64.encode(image);
    if (_anthropic) {
      return {
        'model': model,
        'max_tokens': 300,
        'temperature': 0.1,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': visionPrompt},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': mimeType,
                  'data': b64,
                },
              },
            ],
          },
        ],
      };
    }
    return {
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': visionPrompt},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mimeType;base64,$b64'},
            },
          ],
        },
      ],
      // A short cap keeps verdict latency snappy; the JSON verdict is tiny.
      'max_tokens': 300,
      'temperature': 0.1,
    };
  }

  Map<String, String> _headers() {
    if (_anthropic) {
      return {
        'content-type': 'application/json',
        'anthropic-version': '2023-06-01',
        if (apiKey.isNotEmpty) 'x-api-key': apiKey,
      };
    }
    return {
      'content-type': 'application/json',
      if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
    };
  }

  Future<Map<String, dynamic>> _post(
      Uri uri, Map<String, dynamic> body) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final req = await client.postUrl(uri);
      _headers().forEach(req.headers.set);
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close().timeout(timeout);
      final text = await utf8.decodeStream(res).timeout(timeout);
      if (res.statusCode != 200) {
        throw HttpException('${res.statusCode}: '
            '${text.length > 160 ? text.substring(0, 160) : text}');
      }
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : {};
    } finally {
      client.close();
    }
  }
}

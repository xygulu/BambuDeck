import 'camera_profile.dart';
import 'hcnetsdk.dart';
import 'onvif_ptz.dart';
import 'ptz_client.dart';

/// 云台控制 for the web console: one probed [PtzClient] per camera, shared by
/// every browser that has the page open (probing is the expensive part - an
/// ONVIF SOAP round-trip plus, for EZVIZ, an HCNetSDK login).
///
/// Directions arrive in screen space (right/up positive) exactly like the
/// App's PtzPad; the camera's axis flips are applied here ([ptzMove]). The
/// picture's flip/rotation is not applied to commands at all - the web page
/// draws the pad through the same transform as the video, so the keys follow
/// the picture.
class HubPtz {
  HubPtz({PtzClient Function(CameraProfile camera)? clientFactory})
      : _factory = clientFactory;

  /// Test seam: when set, clients come from here instead of ONVIF/HCNetSDK.
  final PtzClient Function(CameraProfile camera)? _factory;

  final _clients = <String, PtzClient>{};
  final _probing = <String, Future<bool>>{};

  /// Same press-and-hold speed the App's pad uses.
  static const speed = 0.5;

  /// PTZ needs an RTSP URL that carries credentials - the same rule the
  /// App's tile applies before it builds a pad.
  static Uri? ptzUri(CameraProfile c) {
    if (c.sourceType != CameraSourceType.rtsp) return null;
    final u = Uri.tryParse(c.url);
    if (u == null || (u.scheme != 'rtsp' && u.scheme != 'rtsps')) return null;
    if (u.userInfo.isEmpty || u.host.isEmpty) return null;
    return u;
  }

  static bool supported(CameraProfile c) => ptzUri(c) != null;

  /// True once a transport answered. Probes once; concurrent callers share
  /// the in-flight probe.
  Future<bool> probe(CameraProfile c) {
    if (!supported(c)) return Future.value(false);
    final client = _clientFor(c);
    if (client.available) return Future.value(true);
    final pending = _probing[c.id];
    if (pending != null) return pending;
    final f = client.probe().then((ok) => ok, onError: (_) => false);
    _probing[c.id] = f;
    return f.whenComplete(() => _probing.remove(c.id));
  }

  /// Moves the camera. [pan]/[tilt] are screen-space (right / up positive).
  Future<bool> move(CameraProfile c,
      {required double pan, required double tilt}) async {
    if (!await probe(c)) return false;
    final (p, t) = ptzMove(
      invertPan: c.ptzInvertPan,
      invertTilt: c.ptzInvertTilt,
      pan: pan,
      tilt: tilt,
    );
    await _clientFor(c).move(pan: p, tilt: t);
    return true;
  }

  Future<void> stop(CameraProfile c) async {
    final client = _clients[c.id];
    if (client == null) return;
    await client.stop();
  }

  /// Forgets one camera (profile edited / removed) so the next press probes
  /// again with the new credentials.
  void forget(String cameraId) {
    _clients.remove(cameraId)?.dispose();
  }

  void dispose() {
    for (final client in _clients.values) {
      client.dispose();
    }
    _clients.clear();
  }

  PtzClient _clientFor(CameraProfile c) => _clients.putIfAbsent(c.id, () {
        final make = _factory;
        if (make != null) return make(c);
        final u = ptzUri(c)!;
        final sep = u.userInfo.indexOf(':');
        final user = sep < 0 ? u.userInfo : u.userInfo.substring(0, sep);
        final pass =
            sep < 0 ? '' : Uri.decodeComponent(u.userInfo.substring(sep + 1));
        // ONVIF first (generic cameras, and EZVIZ with ONVIF enabled), then
        // the HIK command port for EZVIZ units that disabled ONVIF.
        return FallbackPtz([
          OnvifPtz(host: u.host, username: user, password: pass),
          HcNetSdkPtz(host: u.host, username: user, password: pass),
        ]);
      });
}

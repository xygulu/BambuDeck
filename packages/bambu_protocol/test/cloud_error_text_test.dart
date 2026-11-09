import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('friendlyCloudError', () {
    test('风控 403 / captcha 页面翻译成可操作的指引', () {
      // 拓竹给短信接口套了 Cloudflare 机器人校验, 原始体是一页 HTML。
      expect(friendlyCloudError(403, '<html>Just a moment...</html>'),
          contains('风控'));
      expect(friendlyCloudError(200, '{"error":"please complete captcha"}'),
          contains('风控'));
      expect(friendlyCloudError(403, ''), contains('Token'));
    });

    test('429 明确说是限流, 不是密码错', () {
      expect(friendlyCloudError(429, ''), contains('限流'));
    });

    test('密码错误翻译成中文, 其余保留服务端原话', () {
      expect(
          friendlyCloudError(200, '{"error":"Incorrect account or password."}'),
          '账号或密码不正确。');
      expect(friendlyCloudError(500, '{"error":"boom"}'), contains('boom'));
    });
  });
}

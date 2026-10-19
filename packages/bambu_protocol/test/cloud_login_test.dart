import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('code channel routing: phone numbers go by SMS, emails by mail',
      () {
    expect(isEmailAccount('13800138000'), isFalse);
    expect(isEmailAccount('+8613800138000'), isFalse);
    expect(isEmailAccount('user@example.com'), isTrue);
    expect(isEmailAccount('user.name+tag@sub.example.cn'), isTrue);
  });
}

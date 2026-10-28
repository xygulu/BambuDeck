import 'dart:io';

import 'package:deck/data/lan_printer_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('encodeMqttConnect', () {
    test('encodes a well-formed 3.1.1 CONNECT with bblp credentials', () {
      final bytes = encodeMqttConnect(
          clientId: 'x', password: '12345678', keepAlive: 30);
      // 10 1D | 0004 "MQTT" | 04 | C2 | 001E | 0001 "x" | 0004 "bblp"
      //      | 0008 "12345678"
      expect(
        bytes,
        [
          0x10, 0x1D, //
          0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, //
          0x04, 0xC2, 0x00, 0x1E, //
          0x00, 0x01, 0x78, //
          0x00, 0x04, 0x62, 0x62, 0x6C, 0x70, //
          0x00, 0x08, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        ],
      );
    });

    test('varint remaining length carries past 127 bytes', () {
      final bytes = encodeMqttConnect(
        clientId: 'a' * 128,
        password: 'b' * 128,
        keepAlive: 60,
      );
      // payload = "MQTT"(6) + level/flags/ka(4) + clientId(2+128)
      //         + username(2+4) + password(2+128) = 276 → 编码 0x94 0x02
      expect(bytes[0], 0x10);
      expect(bytes[1], 0x94);
      expect(bytes[2], 0x02);
      // keepalive 60 在可变头末两字节 (大端)
      expect(bytes[11], 0);
      expect(bytes[12], 60);
    });
  });

  group('readMqttConnack', () {
    test('rc=0 counts as accepted', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final client = await Socket.connect('127.0.0.1', server.port);
      server.listen((s) => s.add([0x20, 0x02, 0x00, 0x00]));
      expect(
        await readMqttConnack(client, const Duration(seconds: 2)),
        isTrue,
      );
      client.destroy();
      await server.close();
    });

    test('nonzero rc counts as rejected', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final client = await Socket.connect('127.0.0.1', server.port);
      server.listen((s) => s.add([0x20, 0x02, 0x00, 0x05]));
      expect(
        await readMqttConnack(client, const Duration(seconds: 2)),
        isFalse,
      );
      client.destroy();
      await server.close();
    });

    test('server that never answers times out to false', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final client = await Socket.connect('127.0.0.1', server.port);
      server.listen((_) {}); // 收下不回
      expect(
        await readMqttConnack(client, const Duration(milliseconds: 300)),
        isFalse,
      );
      client.destroy();
      await server.close();
    });
  });
}

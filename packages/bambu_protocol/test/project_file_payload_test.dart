import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('buildProjectFilePayload pins the wire shape the A1 accepts', () {
    final p = buildProjectFilePayload(
      sequenceId: '2041',
      url: 'ftp:///cache/bambudeck_plate_swap.3mf',
      md5: 'abc123',
      name: '自动换盘',
    );
    final node = p['print'] as Map<String, dynamic>;
    expect(node['command'], 'project_file');
    expect(node['sequence_id'], '2041');
    expect(node['param'], 'Metadata/plate_1.gcode');
    expect(node['url'], 'ftp:///cache/bambudeck_plate_swap.3mf');
    expect(node['md5'], 'abc123');
    expect(node['subtask_name'], '自动换盘');
    // A1 has no AMS; local prints must not touch the AMS path.
    expect(node['use_ams'], false);
    expect(node['bed_leveling'], true);
    expect(node['flow_cali'], false);
    expect(node['vibration_cali'], false);
    expect(node['layer_inspect'], false);
    expect(node['timelapse'], false);
  });

  test('empty md5 is omitted (printer rejects empty strings on some fw)', () {
    final p = buildProjectFilePayload(sequenceId: '1', url: 'ftp:///cache/x.3mf');
    final node = p['print'] as Map<String, dynamic>;
    expect(node.containsKey('md5'), isFalse);
  });

  test('secured url_enc replaces cleartext url (§10.3)', () {
    final p = buildProjectFilePayload(
      sequenceId: '2042',
      url: 'ftp:///cache/bambudeck_plate_swap.3mf',
      urlEnc: 'Kj9w8...==',
    );
    final node = p['print'] as Map<String, dynamic>;
    expect(node['url_enc'], 'Kj9w8...==');
    expect(node.containsKey('url'), isFalse);
  });

  test('developer mode keeps cleartext url, no url_enc', () {
    final p = buildProjectFilePayload(
      sequenceId: '2043',
      url: 'ftp:///cache/bambudeck_plate_swap.3mf',
    );
    final node = p['print'] as Map<String, dynamic>;
    expect(node['url'], 'ftp:///cache/bambudeck_plate_swap.3mf');
    expect(node.containsKey('url_enc'), isFalse);
  });
}

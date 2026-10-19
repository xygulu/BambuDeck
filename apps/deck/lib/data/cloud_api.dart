import 'package:bambu_protocol/bambu_protocol.dart';
import 'dart:io';

/// Cloud-facing helpers for the add-printer flow. Injectable for tests.
abstract class CloudApi {
  String? userIdFromToken(String token);
  Future<List<CloudDevice>> devices(String token, CloudRegion region);
}

class HttpCloudApi implements CloudApi {
  @override
  String? userIdFromToken(String token) => extractCloudUserId(token);

  @override
  Future<List<CloudDevice>> devices(String token, CloudRegion region) =>
      fetchCloudDevices(token, region, client: HttpClient());
}

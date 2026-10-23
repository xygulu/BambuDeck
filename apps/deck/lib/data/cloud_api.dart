import 'package:bambu_protocol/bambu_protocol.dart';
import 'dart:io';

/// Cloud-facing helpers for the add-printer flow. Injectable for tests.
abstract class CloudApi {
  Future<String?> userIdFromToken(String token, CloudRegion region);
  Future<List<CloudDevice>> devices(String token, CloudRegion region);
}

class HttpCloudApi implements CloudApi {
  @override
  Future<String?> userIdFromToken(String token, CloudRegion region) =>
      resolveCloudUserId(token, region);

  @override
  Future<List<CloudDevice>> devices(String token, CloudRegion region) =>
      fetchCloudDevices(token, region, client: HttpClient());
}

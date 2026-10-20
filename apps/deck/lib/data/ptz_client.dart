/// Common press-and-hold PTZ surface for a monitoring tile's directional pad.
/// Two transports implement it: [OnvifPtz] (generic ONVIF cameras) and
/// [HcNetSdkPtz] (Hikvision/EZVIZ cameras over the HCNetSDK command port).
abstract class PtzClient {
  bool get available;
  Future<bool> probe();
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0});
  Future<void> stop();
  void dispose();
}

/// Probes [clients] in order and delegates to the first one that reports
/// available. An EZVIZ camera with ONVIF disabled falls back to its
/// command-port client; a generic ONVIF camera never reaches the HCNetSDK
/// client because ONVIF answers first.
class FallbackPtz implements PtzClient {
  FallbackPtz(this._clients);

  final List<PtzClient> _clients;
  PtzClient? _active;

  @override
  bool get available => _active != null;

  @override
  Future<bool> probe() async {
    for (final client in _clients) {
      try {
        if (await client.probe()) {
          _active = client;
          return true;
        }
      } catch (_) {
        // try the next transport
      }
    }
    return false;
  }

  @override
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    await _active?.move(pan: pan, tilt: tilt, zoom: zoom);
  }

  @override
  Future<void> stop() async {
    await _active?.stop();
  }

  @override
  void dispose() {
    for (final client in _clients) {
      client.dispose();
    }
  }
}

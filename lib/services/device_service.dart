import '../models/models.dart';
import 'api_client.dart';

/// The devices the panel has bound to the signed-in subscription.
///
/// The list lives on the panel rather than on this machine: it is what explains
/// "device limit reached" and it is the only place from which a binding can be
/// released, so the client shows it instead of only reporting the message.
class DeviceService {
  DeviceService(this._api);

  final ApiClient _api;

  Future<HwidDevices> fetchDevices() async {
    final res = await _api.get<Map<String, dynamic>>('/api/profile/hwid-devices');
    return HwidDevices.fromJson(res.data ?? const <String, dynamic>{});
  }

  Future<void> removeDevice(String hwid) async {
    await _api.post('/api/profile/hwid-devices/remove', data: {'hwid': hwid});
  }

  Future<void> removeAllDevices() async {
    await _api.post('/api/profile/hwid-devices/remove-all');
  }
}

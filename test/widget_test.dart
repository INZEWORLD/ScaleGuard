import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/config/app_config.dart';
import 'package:scaleguard_mobile/services/vpn_service.dart';

void main() {
  test('AppConfig has default API URL', () {
    expect(AppConfig.appName, 'ScaleGuard');
  });

  test('VpnService uses the custom native bridge payload for startup', () {
    final payload = VpnService.buildNativeBridgeOptions();

    expect(payload['enable'], isTrue);
    expect(payload['port'], equals(7890));
    expect(payload['dnsServerAddress'], isA<String>());
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/models/models.dart';
import 'package:scaleguard_mobile/services/storage_service.dart';

void main() {
  test('profile snapshot survives a cache round-trip', () {
    final snapshot = ProfileSnapshot(
      user: PublicUser(
        id: 42,
        email: 'user@example.com',
        name: 'Тест',
        balance: 120.5,
        role: 'user',
        hasTg: true,
        hasYandex: false,
        telegramId: 123456,
        subscriptionPlanId: 7,
        autoRenewEnabled: true,
      ),
      tunnel: TunnelInfo(
        status: 'ACTIVE',
        subscriptionUrl: 'https://panel.example/sub/abc',
        expireAt: '2026-11-01T00:00:00.000Z',
        trafficLimitBytes: 1000,
        usedTrafficBytes: 250,
        username: 'scale_42',
        uuid: 'f4a0c0de',
      ),
      trial: TrialInfo(
        enabled: true,
        available: false,
        activated: true,
        durationDays: 2,
      ),
    );

    final restored = ProfileSnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
    );

    expect(restored.user.id, 42);
    expect(restored.user.email, 'user@example.com');
    expect(restored.user.autoRenewEnabled, isTrue);
    expect(restored.tunnel.status, 'ACTIVE');
    expect(restored.tunnel.hasActiveSubscription, isTrue);
    expect(restored.tunnel.usedTrafficBytes, 250);
    expect(restored.trial.activated, isTrue);
    expect(restored.trial.durationDays, 2);
  });

  test('offline node cache keeps the proxy definition intact', () {
    final profile = VpnServerProfile(
      remark: '🇳🇱 Нидерланды · Reality',
      configJson: '',
      protocol: 'vless',
      server: 'node.example.com',
      port: 443,
      countryCode: 'NL',
      proxy: {
        'name': '🇳🇱 Нидерланды · Reality',
        'type': 'vless',
        'server': 'node.example.com',
        'port': 443,
        'uuid': 'f4a0c0de-0000-0000-0000-000000000000',
        'tls': true,
        'reality-opts': {'public-key': 'pk', 'short-id': 'abcd'},
        'ws-opts': {
          'path': '/ws',
          'headers': {'Host': 'node.example.com'},
        },
      },
    );

    final restored = VpnServerProfile.fromJson(
      jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
    );

    expect(restored.remark, profile.remark);
    expect(restored.protocol, 'vless');
    expect(restored.server, 'node.example.com');
    expect(restored.port, 443);
    expect(restored.countryCode, 'NL');
    expect(restored.proxy['uuid'], profile.proxy['uuid']);
    expect((restored.proxy['reality-opts'] as Map)['public-key'], 'pk');
    expect(
      ((restored.proxy['ws-opts'] as Map)['headers'] as Map)['Host'],
      'node.example.com',
    );
    expect(jsonDecode(restored.configJson), restored.proxy);
  });

  test('connection cache survives a disk round-trip and can be cleared', () async {
    final directory = await Directory.systemTemp.createTemp('sg-cache-');
    addTearDown(() => directory.delete(recursive: true));
    final storage = StorageService(supportDirectory: directory.path);
    const payload = '{"version":1,"profiles":[]}';

    expect(await storage.readConnectionCache(), isNull);
    await storage.saveConnectionCache(payload);
    expect(await storage.readConnectionCache(), payload);

    await storage.clearConnectionCache();
    expect(await storage.readConnectionCache(), isNull);
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/models/models.dart';

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
}

import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/windows_kill_switch.dart';

/// Checks on the scripts the kill switch runs.
///
/// The firewall itself cannot be exercised from a test — changing a machine's
/// default outbound action is not something a test suite gets to do — so what is
/// checked here is the part that would be a disaster to get wrong: the order in
/// which the rules and the setting are applied, and the quoting of the paths that
/// go into them. `tool/verify_kill_switch.dart` additionally has Windows parse
/// these scripts, which catches anything the text-level checks miss.
void main() {
  const core = r'C:\Moryx VPN\ScaleGuard Mobile App\test\mihomo.exe';
  const client = r'C:\Program Files\ScaleGuard\scaleguard mobile.exe';
  const backup = r'C:\Users\someone\AppData\Roaming\ScaleGuard\kill-switch.json';

  group('enable script', () {
    final script = WindowsKillSwitch.enableScript(
      corePath: core,
      clientPath: client,
      backupFilePath: backup,
    );

    test('creates every allow rule before it blocks anything', () {
      final block = script.indexOf('-DefaultOutboundAction Block');
      expect(block, isPositive, reason: 'the default action is never set');
      for (final rule in <String>['core', 'client', 'loopback', 'lan']) {
        final created = script.indexOf("-DisplayName 'ScaleGuard: $rule'");
        expect(created, isPositive, reason: '$rule is never allowed');
        expect(
          created,
          lessThan(block),
          reason: '$rule must exist before the default action turns to Block',
        );
      }
    });

    test('allows the core, the client, loopback and the local subnet', () {
      expect(script, contains('-Direction Outbound -Action Allow'));
      expect(script, contains('-RemoteAddress 127.0.0.0/8,::1'));
      expect(script, contains('-RemoteAddress LocalSubnet'));
    });

    test('quotes program paths so spaces stay part of the path', () {
      expect(script, contains("-Program '$core'"));
      expect(script, contains("-Program '$client'"));
    });

    test('records the previous actions before it changes them', () {
      expect(script.indexOf('DefaultOutboundAction.ToString()'),
          lessThan(script.indexOf('-DefaultOutboundAction Block')));
      expect(script.indexOf('Set-Content -Path'), isPositive);
    });

    test('reports success with a token, not with an exit code', () {
      expect(script.trimRight(), endsWith("'sg-armed'"));
    });
  });

  group('tunnel script', () {
    test('removes a stale rule first, then allows the adapter', () {
      final script = WindowsKillSwitch.tunnelScript(adapterName: 'ScaleGuard');
      expect(
        script.indexOf('Remove-NetFirewallRule'),
        lessThan(script.indexOf('New-NetFirewallRule')),
      );
      expect(script, contains("-InterfaceAlias 'ScaleGuard'"));
      expect(script.trimRight(), endsWith("'sg-tunnel'"));
    });
  });

  group('disable script', () {
    test('restores every profile, then removes the rules', () {
      final script = WindowsKillSwitch.disableScript(const <String, String>{
        'Domain': 'Allow',
        'Private': 'Block',
        'Public': 'NotConfigured',
      });
      for (final entry in const <String, String>{
        'Domain': 'Allow',
        'Private': 'Block',
        'Public': 'NotConfigured',
      }.entries) {
        expect(script, contains("-Profile ${entry.key} "
            '-DefaultOutboundAction ${entry.value}'));
      }
      expect(
        script.indexOf('-DefaultOutboundAction Allow'),
        lessThan(script.indexOf('Remove-NetFirewallRule')),
        reason: 'the machine must be unblocked before its rules disappear',
      );
      expect(script, contains("'Domain' = 'Allow'"));
    });

    test('checks the result instead of trusting the command', () {
      final script = WindowsKillSwitch.disableScript(const <String, String>{
        'Domain': 'Allow',
        'Private': 'Allow',
        'Public': 'Allow',
      });
      expect(script, contains(r'$mismatch'));
      // Inside an if/else on the last line, which is what reports the outcome.
      expect(script, contains("else { 'sg-released' }"));
    });
  });

  group('failsafe script', () {
    final script = WindowsKillSwitch.releaseScript(backupFilePath: backup);

    test('leaves the machine alone while the client is running', () {
      // Must match the built executable (ScaleGuard.exe): a stale name would
      // let the failsafe release the switch while the client is healthy.
      expect(script, contains('-Name ScaleGuard'));
      expect(
        script.indexOf(r'exit 0'),
        lessThan(script.indexOf('Set-NetFirewallProfile')),
        reason: 'the client being alive has to end the script before it acts',
      );
    });

    test('restores the recorded actions and removes the rules', () {
      expect(script, contains(r'$state.previous.$profile'));
      expect(script, contains("-DisplayName 'ScaleGuard: *'"));
      expect(script, contains('Remove-Item -Path'));
    });

    test('deletes itself once it has released the machine', () {
      expect(script, contains('schtasks /delete /f /tn'));
      // Twice: the early exit for "nothing to restore" also cleans up. The one
      // that matters is the last, which must come after the restore.
      expect(script.lastIndexOf('schtasks /delete'),
          greaterThan(script.lastIndexOf('-DefaultOutboundAction')));
    });
  });

  group('verify script', () {
    test('judges the machine, not the previous command', () {
      final script = WindowsKillSwitch.verifyScript();
      expect(script, contains(r"@('Domain', 'Private', 'Public')"));
      expect(script, contains("'sg-blocking'"));
      expect(script, contains("'sg-open'"));
    });

    test('is read-only, so it can never change what it checks', () {
      final script = WindowsKillSwitch.verifyScript();
      expect(script, isNot(contains('Set-NetFirewallProfile')));
      expect(script, isNot(contains('New-NetFirewallRule')));
      expect(script, isNot(contains('Remove-NetFirewallRule')));
      expect(script, isNot(contains('Remove-Item')));
    });
  });

  test('single quotes in a path are doubled for PowerShell', () {
    final script = WindowsKillSwitch.enableScript(
      corePath: r"C:\it's here\mihomo.exe",
      clientPath: client,
      backupFilePath: backup,
    );
    expect(script, contains(r"-Program 'C:\it''s here\mihomo.exe'"));
  });
}

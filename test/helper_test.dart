import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/windows_helper.dart';

/// Checks on the task definition behind the promptless elevated launch.
///
/// The task itself can only be registered from an elevated session, so what is
/// checked here is the definition — which contains the two properties that decide
/// whether the helper is useful at all and whether it is well behaved:
/// `HighestAvailable` (the reason there is no UAC prompt) and an empty
/// `<Triggers />` (the reason it never starts the client on its own).
void main() {
  const user = r'DESKTOP-ABC\vygar';
  const exe = r'C:\Moryx VPN\ScaleGuard Mobile App\ScaleGuard.exe';

  final xml = WindowsHelper.taskXml(userId: user, executable: exe);

  test('runs with the highest available rights, which is the whole point', () {
    expect(xml, contains('<RunLevel>HighestAvailable</RunLevel>'));
    // The interactive token is what makes a password unnecessary, and it keeps
    // the client in the user's own session, where its window and tray icon live.
    expect(xml, contains('<LogonType>InteractiveToken</LogonType>'));
    expect(xml, contains('<UserId>$user</UserId>'));
  });

  test('has no triggers, so it never starts the client by itself', () {
    expect(xml, contains('<Triggers />'));
    expect(xml, isNot(contains('<LogonTrigger')));
    expect(xml, isNot(contains('<TimeTrigger')));
    expect(xml, isNot(contains('<CalendarTrigger')));
  });

  test('may be started on demand and is enabled', () {
    expect(xml, contains('<AllowStartOnDemand>true</AllowStartOnDemand>'));
    // Not created disabled: Windows refuses to start a disabled task, which
    // would make the helper answer every launch with a refusal.
    expect(xml, contains('<Enabled>true</Enabled>'));
  });

  test('starts exactly this executable', () {
    expect(xml, contains('<Command>$exe</Command>'));
  });

  test('starts it from its own directory, not from system32', () {
    expect(
      xml,
      contains(
        '<WorkingDirectory>'
        r'C:\Moryx VPN\ScaleGuard Mobile App'
        '</WorkingDirectory>',
      ),
    );
  });

  test('never stops the client it started', () {
    // `PT0S` is the task scheduler's "no time limit"; anything shorter would cut
    // a long session off.
    expect(xml, contains('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'));
    expect(xml, isNot(contains('StopIfGoingOnBatteries>true')));
    expect(xml, isNot(contains('DisallowStartIfOnBatteries>true')));
  });

  test('escapes the path so a folder with an ampersand stays valid XML', () {
    final escaped = WindowsHelper.taskXml(
      userId: user,
      executable: r'C:\Tools & Games\ScaleGuard\ScaleGuard.exe',
    );
    expect(escaped, contains(r'C:\Tools &amp; Games'));
    expect(escaped, isNot(contains(r'C:\Tools & Games')));
  });
}

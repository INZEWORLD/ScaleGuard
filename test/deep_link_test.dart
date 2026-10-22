import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/windows_deep_link.dart';

/// Checks on the hand-off that carries a login back into the application.
///
/// This is the part that failed silently in the field: with "always run as
/// administrator" on, the browser's `scaleguard://…` activation is answered by a
/// process that is about to be replaced by an elevated one, and the URL died
/// with it — the login simply never happened. Two things have to hold for that
/// not to recur: the URL must be recognised in the process's own arguments, and
/// it must survive being written to disk and read back exactly once.
void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('sg-deeplink-test');
    WindowsPendingDeepLink.directoryOverride = sandbox.path;
  });

  tearDown(() {
    WindowsPendingDeepLink.directoryOverride = null;
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('reading the URL out of the arguments', () {
    test('finds the protocol link among ordinary switches', () {
      const link = 'scaleguard://oauth?oauth=login&oauth_token=abc';
      expect(
        WindowsSingleInstanceGate.launchUriFrom(
          <String>['--keep-log', link],
        ),
        link,
      );
    });

    test('ignores a launch that carries no link', () {
      expect(WindowsSingleInstanceGate.launchUriFrom(<String>[]), isNull);
      expect(
        WindowsSingleInstanceGate.launchUriFrom(<String>['--keep-log']),
        isNull,
      );
    });

    test('tolerates the quotes Windows leaves around the argument', () {
      expect(
        WindowsSingleInstanceGate.launchUriFrom(
          <String>[' "scaleguard://oauth?oauth_token=abc" '],
        ),
        'scaleguard://oauth?oauth_token=abc',
      );
    });
  });

  group('parked link', () {
    test('comes back exactly as it was left', () async {
      const link = 'scaleguard://oauth?oauth=login&oauth_token=eyJhbGciOi';
      expect(await WindowsPendingDeepLink.store(link), isTrue);
      expect(await WindowsPendingDeepLink.consume(), link);
    });

    test('is used once and never replayed', () async {
      await WindowsPendingDeepLink.store('scaleguard://oauth?oauth_token=abc');
      expect(await WindowsPendingDeepLink.consume(), isNotNull);
      expect(await WindowsPendingDeepLink.consume(), isNull);
    });

    test('is empty when nothing was parked', () async {
      expect(await WindowsPendingDeepLink.consume(), isNull);
    });

    test('refuses a link that sat around past its lifetime', () async {
      final file = File(
        '${sandbox.path}${Platform.pathSeparator}pending-deep-link.txt',
      );
      final stale = DateTime.now()
          .subtract(WindowsPendingDeepLink.maxAge + const Duration(minutes: 1))
          .millisecondsSinceEpoch;
      file.writeAsStringSync('$stale\nscaleguard://oauth?oauth_token=abc');
      expect(await WindowsPendingDeepLink.consume(), isNull);
      // And it does not stay behind waiting to fail again next start.
      expect(file.existsSync(), isFalse);
    });

    test('survives a written file that makes no sense', () async {
      final file = File(
        '${sandbox.path}${Platform.pathSeparator}pending-deep-link.txt',
      );
      file.writeAsStringSync('not a stamp');
      expect(await WindowsPendingDeepLink.consume(), isNull);
    });

    test('clears a parked link without using it', () async {
      await WindowsPendingDeepLink.store('scaleguard://oauth?oauth_token=abc');
      await WindowsPendingDeepLink.clear();
      expect(await WindowsPendingDeepLink.consume(), isNull);
    });

    test('ignores anything that is not our scheme', () async {
      expect(
        await WindowsPendingDeepLink.store('https://example.com/oauth'),
        isTrue,
      );
      // Only the gate decides what counts as a link; the store is a plain file.
      expect(await WindowsPendingDeepLink.consume(), 'https://example.com/oauth');
    });
  });
}

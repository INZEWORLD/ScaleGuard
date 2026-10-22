import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/qr_link.dart';

/// Checks on what a scanned code is allowed to mean.
///
/// A camera is an untrusted input: it reads whatever is held in front of it, so
/// the parser is the boundary between "a code from another ScaleGuard" and
/// "anything at all". Only a session identifier may cross it, and everything
/// else has to come back as `null` rather than as a request to the panel.
void main() {
  const session = 'kJ8sQ2mNv1pR7tY4wZ6xB9cD3fH5jL0aG2sV8nM4qW7e';

  group('recognising the link the panel hands out', () {
    test('reads the session out of our own scheme', () {
      expect(qrSessionIdFromLink('scaleguard://qr?session=$session'), session);
    });

    test('reads it out of any URL that carries one', () {
      expect(
        qrSessionIdFromLink('https://scaleguard.inzeworld.com/qr?session=$session'),
        session,
      );
    });

    test('accepts an identifier typed instead of scanned', () {
      expect(qrSessionIdFromLink('  $session\n'), session);
    });
  });

  group('refusing everything else', () {
    test('rejects an empty or blank code', () {
      expect(qrSessionIdFromLink(''), isNull);
      expect(qrSessionIdFromLink('   '), isNull);
    });

    test('rejects a link without a session', () {
      expect(qrSessionIdFromLink('scaleguard://qr'), isNull);
      expect(qrSessionIdFromLink('https://example.com/'), isNull);
    });

    test('rejects an OAuth return link', () {
      expect(
        qrSessionIdFromLink('scaleguard://oauth?oauth_token=$session'),
        isNull,
      );
    });

    test('rejects a session that is too short to be one', () {
      expect(qrSessionIdFromLink('scaleguard://qr?session=abc'), isNull);
      expect(qrSessionIdFromLink('abc'), isNull);
    });

    test('rejects a product barcode', () {
      expect(qrSessionIdFromLink('4601234567890'), isNull);
      expect(qrSessionIdFromLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
          isNull);
    });
  });
}

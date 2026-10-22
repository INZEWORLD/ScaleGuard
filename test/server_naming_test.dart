import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/server_naming.dart';

void main() {
  group('locationLabel', () {
    test('drops the flag from a plain remark', () {
      expect(locationLabel('🇸🇪 Стокгольм'), 'Стокгольм');
    });

    test('keeps the city and drops the subscription index', () {
      expect(locationLabel('🇳🇱 Нидерланды | #2'), 'Нидерланды');
    });

    test('takes the part before a separator', () {
      expect(locationLabel('🇫🇮 Финляндия · Хельсинки'), 'Финляндия');
    });

    test('keeps a name that has nothing to strip', () {
      expect(locationLabel('Стокгольм'), 'Стокгольм');
      expect(locationLabel('Москва (Telegram не работает)'), 'Москва (Telegram не работает)');
    });

    test('never answers with an empty string', () {
      expect(locationLabel('🇸🇪'), isNotEmpty);
      expect(locationLabel(''), '');
    });
  });
}

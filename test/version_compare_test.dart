import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/version_compare.dart';

void main() {
  test('release tags compare numerically, not lexicographically', () {
    expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('1.2', '1.2.0'), 0);
    expect(compareVersions('v1.0.1', '1.0.0'), greaterThan(0));
  });

  test('build suffixes are ignored', () {
    expect(compareVersions('1.1.1+7', '1.1.0+2'), greaterThan(0));
    expect(compareVersions('1.1.0+2', '1.1.0+9'), 0);
  });

  test('pre-release tails do not make a version newer', () {
    expect(compareVersions('1.2.0-beta.2', '1.2.0'), 0);
    expect(compareVersions('1.2.0-beta.2', '1.1.9'), greaterThan(0));
  });

  test('isNewerVersion only accepts a genuinely newer tag', () {
    expect(isNewerVersion('v1.1.1', '1.1.0'), isTrue);
    expect(isNewerVersion('v1.1.0', '1.1.0'), isFalse);
    expect(isNewerVersion('v1.0.9', '1.1.0'), isFalse);
    expect(isNewerVersion('', '1.1.0'), isFalse);
  });
}

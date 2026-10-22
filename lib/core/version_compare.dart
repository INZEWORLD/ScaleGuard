/// Version comparisons for the self-updater.
///
/// Release tags are `v1.2.3`, `1.2.3`, often with a `+4` build suffix (the
/// Play/Flutter build number) and occasionally a pre-release tail such as
/// `-beta.2`. Only the leading numeric parts decide whether an update exists:
/// the build number is not comparable across platforms, and a beta should not
/// be offered to a stable install.
library;

/// Returns a negative number when [a] is older than [b], zero when the two
/// versions are equivalent and a positive number when [a] is newer.
int compareVersions(String a, String b) {
  final left = _numbers(a);
  final right = _numbers(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

/// `true` when [candidate] is a release the running build should install.
bool isNewerVersion(String candidate, String current) =>
    compareVersions(candidate, current) > 0;

/// The numeric segments of a version string, in order.
///
/// `v1.2.3+4` -> `[1, 2, 3]`; `1.2` -> `[1, 2]`; anything that is not a
/// version at all -> `[]`, which compares as zero.
List<int> _numbers(String raw) {
  var value = raw.trim();
  if (value.startsWith('v') || value.startsWith('V')) {
    value = value.substring(1);
  }
  // A pre-release tail is part of the text, not of the release ordering this
  // updater uses. GitHub only returns the latest stable release, so dropping
  // it is enough to keep `1.2.3-beta` from being read as `1.2.3`.
  final plus = value.indexOf('+');
  if (plus >= 0) value = value.substring(0, plus);
  final dash = value.indexOf('-');
  if (dash >= 0) value = value.substring(0, dash);
  final result = <int>[];
  for (final part in value.split('.')) {
    final match = RegExp(r'^\d+').firstMatch(part.trim());
    if (match == null) break;
    result.add(int.tryParse(match.group(0)!) ?? 0);
  }
  return result;
}

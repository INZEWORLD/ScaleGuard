/// Parsing for the user's own "go direct" domain list.
///
/// The connection settings screen accepts anything a person might paste — a full
/// URL, a bare host, a `www.`-prefixed name, an address with a port or a path —
/// and this turns all of it into a clean, deduplicated list that can be written
/// into the core profile as routing rules. Being permissive on input and strict
/// on output is what makes the field safe: a malformed entry is dropped instead
/// of producing YAML the core would refuse to load.
library;

/// Upper bound on the stored list.
///
/// The list travels through the platform secret store, and the Windows
/// implementation of it is the Credential Manager, whose blob is capped at
/// 2560 bytes. Staying well below that keeps a long list from turning into a
/// failed save, and a hundred domains is far more than a bypass list needs.
const int maxBypassDomains = 100;

/// Character budget for the same reason as [maxBypassDomains].
const int maxBypassCharacters = 1500;

/// Splits pasted text into normalised domains.
///
/// Accepts commas, semicolons, whitespace and newlines as separators, so
/// `123.com, https://www.youtube.com, sakyr.org` and one-per-line both work.
List<String> parseBypassDomains(
  String raw, {
  int limit = maxBypassDomains,
}) {
  final seen = <String>{};
  final result = <String>[];
  for (final chunk in raw.split(RegExp(r'[\s,;]+'))) {
    if (chunk.isEmpty) continue;
    final domain = normalizeDomain(chunk);
    if (domain == null) continue;
    if (!seen.add(domain)) continue;
    result.add(domain);
    if (result.length >= limit) break;
  }
  return result;
}

/// Normalises one entry, or returns `null` when it is not a host at all.
///
/// `https://www.YouTube.com/watch?v=1` becomes `youtube.com`: the scheme, the
/// path and the `www.` prefix are all noise for a suffix match, and dropping the
/// prefix is what lets one entry cover `youtube.com`, `www.youtube.com` and
/// `m.youtube.com` alike.
String? normalizeDomain(String raw) {
  var value = raw.trim().toLowerCase();
  if (value.isEmpty) return null;

  final scheme = value.indexOf('://');
  if (scheme >= 0) value = value.substring(scheme + 3);

  // Credentials, port, path, query and fragment all end the host.
  final cut = value.indexOf(RegExp(r'[/?#]'));
  if (cut >= 0) value = value.substring(0, cut);
  final at = value.indexOf('@');
  if (at >= 0) value = value.substring(at + 1);
  final colon = value.indexOf(':');
  if (colon >= 0) value = value.substring(0, colon);

  // A trailing dot is legal in DNS (`example.com.`) but not in a rule.
  while (value.startsWith('.')) {
    value = value.substring(1);
  }
  while (value.endsWith('.')) {
    value = value.substring(0, value.length - 1);
  }
  if (value.startsWith('*.')) value = value.substring(2);
  if (value.startsWith('www.') && value.length > 4) value = value.substring(4);

  if (value.isEmpty) return null;
  if (isIpv4(value)) return value;
  if (!_hostname.hasMatch(value)) return null;
  // A single label (`localhost`) is not a domain and has no business in the
  // bypass list; private ranges are already routed directly by the profile.
  if (!value.contains('.')) return null;
  return value;
}

/// Renders a list back into the comma-separated form the field shows.
String formatBypassDomains(Iterable<String> domains) => domains.join(', ');

/// Whether [value] is a dotted-quad IPv4 address.
bool isIpv4(String value) {
  final match = _ipv4.firstMatch(value);
  if (match == null) return false;
  for (var index = 1; index <= 4; index++) {
    final octet = int.parse(match.group(index)!);
    if (octet > 255) return false;
  }
  return true;
}

final RegExp _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

final RegExp _hostname = RegExp(
  r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
);

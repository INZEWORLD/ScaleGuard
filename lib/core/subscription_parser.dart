import 'dart:convert';

/// Remnawave can deliver the same subscription in several shapes depending on
/// the client type it detects. A client must therefore understand all of them:
///
///  * `mihomo` / `clash` / `stash` -> a full mihomo YAML profile
///  * `singbox`                     -> sing-box JSON (proxies out of `outbounds`)
///  * `json` / `v2ray-json`         -> Xray JSON (`outbounds`)
///  * fallback (any other UA)       -> base64 of `vless://…` share links
///
/// Everything below normalises those into mihomo **proxy maps**, which are the
/// single currency used by both native cores (the Windows sidecar process and
/// the Android JNI library) and by the UI for display.
class ParsedVpnServer {
  ParsedVpnServer({
    required this.remark,
    required this.protocol,
    required this.server,
    required this.port,
    required this.proxy,
    this.countryCode,
  });

  /// Human readable name from the subscription (usually `🇩🇪 Germany | #1`).
  final String remark;

  /// Lower-case mihomo proxy type: vless, vmess, trojan, ss, hysteria2, …
  final String protocol;

  /// Endpoint address and port, kept separately for latency display and for
  /// the auto-select summary shown on the home screen.
  final String server;
  final int port;

  /// The ready-to-use mihomo `proxies:` entry.
  final Map<String, dynamic> proxy;

  /// Optional ISO-3166 alpha-2 code extracted from the remark (for flags).
  final String? countryCode;

  /// `server:port`, as shown in the UI.
  String get endpoint => '$server:$port';
}

/// Thrown when a subscription body carries no usable server.
class SubscriptionParseException implements Exception {
  SubscriptionParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

const Set<String> _supportedProtocols = {
  'vless',
  'vmess',
  'trojan',
  'ss',
  'ssr',
  'hysteria',
  'hysteria2',
  'tuic',
  'wireguard',
  'http',
  'socks5',
  'snell',
  'anytls',
};

/// Parses a raw subscription body into mihomo proxy maps.
///
/// Returns an empty list instead of throwing when the body is a valid profile
/// that simply contains no servers, and throws
/// [SubscriptionParseException] when nothing at all could be understood.
List<ParsedVpnServer> parseSubscriptionBody(String rawBody) {
  final body = rawBody.trim();
  if (body.isEmpty) {
    throw SubscriptionParseException('Пустой ответ подписки');
  }

  // 1. A full mihomo/Clash profile: the richest source, it already carries
  //    every protocol field Remnawave generated for the panel node.
  final yaml = _tryParseMihomoProfile(body);
  if (yaml.isNotEmpty) return yaml;

  // 2. YAML that failed to parse usually means the body was actually base64.
  final decoded = _tryDecodeBase64(body);
  final candidate = decoded ?? body;

  // 3. Xray/sing-box JSON produced by `json`, `v2ray-json` or `singbox`.
  final jsonServers = _tryParseJsonProfile(candidate);
  if (jsonServers.isNotEmpty) return jsonServers;

  // 4. Plain or base64 share links, one per line.
  final links = _parseShareLinks(candidate);
  if (links.isNotEmpty) return links;

  if (decoded == null) {
    final decodedRetry = _tryDecodeBase64(body);
    if (decodedRetry != null) {
      final retry = _parseShareLinks(decodedRetry);
      if (retry.isNotEmpty) return retry;
    }
  }

  throw SubscriptionParseException(
    'В подписке нет поддерживаемых серверов. Проверьте, что тариф активен.',
  );
}

/// Convenience wrapper used when the body may be base64 *or* plaintext and the
/// caller only wants proxy maps.
List<ParsedVpnServer> parseSubscriptionBodyOrEmpty(String rawBody) {
  try {
    return parseSubscriptionBody(rawBody);
  } on SubscriptionParseException {
    return const [];
  }
}

// ---------------------------------------------------------------------------
// mihomo YAML profiles
// ---------------------------------------------------------------------------

List<ParsedVpnServer> _tryParseMihomoProfile(String body) {
  // Cheap gate first: a YAML profile must mention the proxies key.
  if (!RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(body)) {
    return const [];
  }
  // The body may be base64-wrapped even when the client type says YAML.
  dynamic doc = _loadYamlQuietly(body);
  if (doc is! Map) {
    final decoded = _tryDecodeBase64(body);
    if (decoded == null) return const [];
    doc = _loadYamlQuietly(decoded);
  }
  if (doc is! Map) return const [];
  final proxies = doc['proxies'];
  if (proxies is! List) return const [];
  return _serversFromProxyList(proxies);
}

dynamic _loadYamlQuietly(String body) {
  try {
    return _MiniYaml.parse(body);
  } catch (_) {
    return null;
  }
}

List<ParsedVpnServer> _serversFromProxyList(List<dynamic> proxies) {
  final result = <ParsedVpnServer>[];
  final usedNames = <String>{};
  for (final item in proxies) {
    if (item is! Map) continue;
    final proxy = _normaliseProxyMap(_stringKeyedMap(item));
    final type = proxy['type']?.toString().toLowerCase();
    if (type == null || !_supportedProtocols.contains(type)) continue;
    final server = proxy['server']?.toString() ?? '';
    if (server.isEmpty) continue;
    final port = _asInt(proxy['port']);
    if (port <= 0) continue;

    var name = proxy['name']?.toString().trim() ?? '';
    if (name.isEmpty) name = '$server:$port';
    name = _uniqueName(name, usedNames);

    final normalised = Map<String, dynamic>.from(proxy)..['name'] = name;
    result.add(
      ParsedVpnServer(
        remark: name,
        protocol: type == 'shadowsocks' ? 'ss' : type,
        server: server,
        port: port,
        proxy: normalised,
        countryCode: _countryFromRemark(name),
      ),
    );
  }
  return result;
}

/// Fields whose YAML spelling must stay a number.
const Set<String> _numericProxyFields = {
  'port',
  'alterId',
  'mtu',
  'up',
  'down',
  'max-udp-relay-packet-size',
  'recv-window-conn',
  'recv-window',
  'ip-version',
};

/// Fields whose YAML spelling must stay a boolean.
const Set<String> _booleanProxyFields = {
  'udp',
  'tls',
  'skip-cert-verify',
  'disable-sni',
  'reduce-rtt',
  'udp-over-tcp',
  'tfo',
  'mptcp',
  'xudp',
};

/// Keys whose values are identifiers or credentials that must survive YAML
/// round-tripping as text. `short-id: 0123` otherwise becomes the integer 123
/// (a different Reality short id) and a UUID of all digits would be truncated.
const Set<String> _identifierKeys = {
  'uuid',
  'password',
  'public-key',
  'short-id',
  'private-key',
  'pre-shared-key',
  'auth-str',
  'obfs-password',
  'path',
  'sni',
  'servername',
  'server',
  'name',
  'username',
  'cipher',
  'plugin',
  'grpc-service-name',
  'http-path',
  'h2-path',
  'ws-path',
};

Map<String, dynamic> _normaliseProxyMap(Map<String, dynamic> proxy) {
  final result = <String, dynamic>{};
  proxy.forEach((key, value) {
    if (_numericProxyFields.contains(key)) {
      result[key] = _asInt(value);
      return;
    }
    if (_booleanProxyFields.contains(key)) {
      result[key] = value == true || value?.toString() == 'true';
      return;
    }
    if (key == 'fingerprint') {
      // mihomo spells this `client-fingerprint` on a proxy.
      result['client-fingerprint'] = value.toString();
      return;
    }
    result[key] = _preserveIdentifiers(value);
  });
  return result;
}

/// Recursively converts numbers/booleans back to their textual form, but only
/// under keys that are known identifiers, so a `port: 443` nested in
/// `ws-opts`-like structures is not silently turned into a string.
dynamic _preserveIdentifiers(dynamic value) {
  if (value is Map) {
    final map = <String, dynamic>{};
    value.forEach((key, item) {
      final name = key.toString();
      map[name] = _identifierKeys.contains(name)
          ? (item == null ? null : item.toString())
          : _preserveIdentifiers(item);
    });
    return map;
  }
  if (value is List) return value.map(_preserveIdentifiers).toList();
  return value;
}

// ---------------------------------------------------------------------------
// Xray / sing-box JSON profiles
// ---------------------------------------------------------------------------

List<ParsedVpnServer> _tryParseJsonProfile(String body) {
  final trimmed = body.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return const [];
  dynamic doc;
  try {
    doc = jsonDecode(trimmed);
  } catch (_) {
    return const [];
  }

  final outbounds = <dynamic>[];
  if (doc is Map) {
    final direct = doc['outbounds'];
    if (direct is List) outbounds.addAll(direct);
    final response = doc['response'];
    if (response is Map && response['outbounds'] is List) {
      outbounds.addAll(response['outbounds'] as List);
    }
  } else if (doc is List) {
    outbounds.addAll(doc);
  }

  final result = <ParsedVpnServer>[];
  final usedNames = <String>{};
  for (final outbound in outbounds) {
    if (outbound is! Map) continue;
    final map = _stringKeyedMap(outbound);
    final protocol = map['protocol']?.toString().toLowerCase();
    if (protocol == null) continue;
    // sing-box uses `type` instead of `protocol` and a different layout; the
    // share-link fallback covers those, so only Xray is handled here.
    final parsed = _xrayOutboundToServer(map);
    if (parsed == null) continue;
    final name = _uniqueName(parsed['remark'] as String, usedNames);
    result.add(
      ParsedVpnServer(
        remark: name,
        protocol: parsed['protocol'] as String,
        server: parsed['server'] as String,
        port: parsed['port'] as int,
        proxy: (parsed['proxy'] as Map<String, dynamic>)..['name'] = name,
        countryCode: _countryFromRemark(name),
      ),
    );
  }
  return result;
}

Map<String, dynamic>? _xrayOutboundToServer(Map<String, dynamic> outbound) {
  final tag = outbound['tag']?.toString() ?? '';
  if (tag == 'api' || tag == 'direct' || tag == 'block' || tag == 'dns') {
    return null;
  }
  final protocol = outbound['protocol']?.toString().toLowerCase();
  final settings = outbound['settings'];
  final stream = _stringKeyedMap(outbound['streamSettings']);
  if (settings is! Map) return null;
  final settingsMap = _stringKeyedMap(settings);

  switch (protocol) {
    case 'vless':
    case 'vmess':
      final vnext = settingsMap['vnext'];
      if (vnext is! List || vnext.isEmpty) return null;
      final node = _stringKeyedMap(vnext.first);
      final users = node['users'];
      if (users is! List || users.isEmpty) return null;
      final user = _stringKeyedMap(users.first);
      final address = node['address']?.toString() ?? '';
      final port = _asInt(node['port']);
      if (address.isEmpty || port <= 0) return null;
      final proxy = <String, dynamic>{
        'name': tag.isEmpty ? '$address:$port' : tag,
        'type': protocol,
        'server': address,
        'port': port,
        'udp': true,
      };
      if (protocol == 'vless') {
        proxy['uuid'] = user['id']?.toString() ?? '';
        final flow = user['flow']?.toString() ?? '';
        if (flow.isNotEmpty) proxy['flow'] = flow;
        proxy['network'] = _networkOf(stream);
      } else {
        proxy['uuid'] = user['id']?.toString() ?? '';
        proxy['alterId'] = _asInt(user['alterId']);
        proxy['cipher'] = user['security']?.toString().isNotEmpty == true
            ? user['security'].toString()
            : 'auto';
        proxy['network'] = _networkOf(stream);
      }
      _applyStream(proxy, stream);
      return {
        'remark': proxy['name'] as String,
        'protocol': protocol,
        'server': address,
        'port': port,
        'proxy': proxy,
      };

    case 'trojan':
      final servers = settingsMap['servers'];
      if (servers is! List || servers.isEmpty) return null;
      final node = _stringKeyedMap(servers.first);
      final address = node['address']?.toString() ?? '';
      final port = _asInt(node['port']);
      if (address.isEmpty || port <= 0) return null;
      final proxy = <String, dynamic>{
        'name': tag.isEmpty ? '$address:$port' : tag,
        'type': 'trojan',
        'server': address,
        'port': port,
        'password': node['password']?.toString() ?? '',
        'udp': true,
        'network': _networkOf(stream),
      };
      _applyStream(proxy, stream);
      return {
        'remark': proxy['name'] as String,
        'protocol': 'trojan',
        'server': address,
        'port': port,
        'proxy': proxy,
      };

    case 'shadowsocks':
      final servers = settingsMap['servers'];
      if (servers is! List || servers.isEmpty) return null;
      final node = _stringKeyedMap(servers.first);
      final address = node['address']?.toString() ?? '';
      final port = _asInt(node['port']);
      if (address.isEmpty || port <= 0) return null;
      final proxy = <String, dynamic>{
        'name': tag.isEmpty ? '$address:$port' : tag,
        'type': 'ss',
        'server': address,
        'port': port,
        'cipher': node['method']?.toString() ?? 'aes-128-gcm',
        'password': node['password']?.toString() ?? '',
        'udp': true,
      };
      return {
        'remark': proxy['name'] as String,
        'protocol': 'ss',
        'server': address,
        'port': port,
        'proxy': proxy,
      };
    default:
      return null;
  }
}

String _networkOf(Map<String, dynamic> stream) {
  final network = stream['network']?.toString() ?? 'tcp';
  // mihomo calls Xray's `raw` transport `tcp`.
  return network == 'raw' ? 'tcp' : network;
}

void _applyStream(Map<String, dynamic> proxy, Map<String, dynamic> stream) {
  final security = stream['security']?.toString() ?? 'none';
  final tlsSettings = _stringKeyedMap(stream['tlsSettings']);
  final reality = _stringKeyedMap(stream['realitySettings']);
  final network = proxy['network']?.toString() ?? 'tcp';

  if (network == 'ws' || network == 'httpupgrade' || network == 'xhttp') {
    final ws = _stringKeyedMap(
      stream['wsSettings'] ?? stream['httpupgradeSettings'] ?? stream['xhttpSettings'],
    );
    final path = ws['path']?.toString() ?? '/';
    final host = (ws['host']?.toString().isNotEmpty ?? false)
        ? ws['host'].toString()
        : _firstOf(ws['headers']);
    proxy['ws-opts'] = {
      'path': path,
      if (host.isNotEmpty) 'headers': {'Host': host},
    };
  } else if (network == 'grpc') {
    final grpc = _stringKeyedMap(stream['grpcSettings']);
    final service = grpc['serviceName']?.toString() ?? '';
    proxy['grpc-opts'] = {
      if (service.isNotEmpty) 'grpc-service-name': service,
    };
  } else if (network == 'h2' || network == 'http') {
    final http = _stringKeyedMap(stream['httpSettings']);
    final hosts = http['host'];
    proxy['h2-opts'] = {
      if (hosts is List && hosts.isNotEmpty) 'host': [hosts.first.toString()],
      if (http['path']?.toString().isNotEmpty ?? false)
        'path': http['path'].toString(),
    };
  }

  if (security == 'tls') {
    proxy['tls'] = true;
    final sni = tlsSettings['serverName']?.toString() ?? '';
    if (sni.isNotEmpty) {
      proxy['servername'] = sni;
    }
    if (tlsSettings['allowInsecure'] == true) {
      proxy['skip-cert-verify'] = true;
    }
    final fingerprint = tlsSettings['fingerprint']?.toString() ?? '';
    if (fingerprint.isNotEmpty) proxy['client-fingerprint'] = fingerprint;
    final alpn = tlsSettings['alpn'];
    if (alpn is List && alpn.isNotEmpty) {
      proxy['alpn'] = alpn.map((e) => e.toString()).toList();
    }
  } else if (security == 'reality') {
    proxy['tls'] = true;
    final serverNames = reality['serverNames'] ?? reality['serverName'];
    final sni = serverNames is List && serverNames.isNotEmpty
        ? serverNames.first.toString()
        : serverNames?.toString() ?? '';
    if (sni.isNotEmpty) proxy['servername'] = sni;
    final publicKey = reality['publicKey']?.toString() ??
        reality['pbk']?.toString() ??
        '';
    final shortIds = reality['shortIds'] ?? reality['shortId'];
    final shortId = shortIds is List && shortIds.isNotEmpty
        ? shortIds.first.toString()
        : shortIds?.toString() ?? '';
    final fingerprint = reality['fingerprint']?.toString() ?? '';
    proxy['client-fingerprint'] = fingerprint.isNotEmpty ? fingerprint : 'chrome';
    if (publicKey.isNotEmpty || shortId.isNotEmpty) {
      proxy['reality-opts'] = {
        if (publicKey.isNotEmpty) 'public-key': publicKey,
        if (shortId.isNotEmpty) 'short-id': shortId,
      };
    }
  }
}

String _firstOf(dynamic headers) {
  if (headers is Map) {
    for (final value in headers.values) {
      if (value is List && value.isNotEmpty) return value.first.toString();
      if (value is String && value.isNotEmpty) return value;
    }
  }
  return '';
}

// ---------------------------------------------------------------------------
// Share links (vless://, vmess://, trojan://, ss://, hysteria2://, …)
// ---------------------------------------------------------------------------

List<ParsedVpnServer> _parseShareLinks(String body) {
  final result = <ParsedVpnServer>[];
  final usedNames = <String>{};
  final seen = <String>{};

  for (final rawLine in body.split(RegExp(r'[\r\n]+'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    // A line may hold several links separated by spaces.
    for (final chunk in line.split(RegExp(r'\s+'))) {
      final link = chunk.trim();
      if (!link.contains('://')) continue;
      final fingerprint = link;
      if (!seen.add(fingerprint)) continue;
      try {
        final server = _parseShareLink(link, usedNames);
        if (server != null) result.add(server);
      } catch (_) {
        // A single malformed node must not discard the whole subscription.
      }
    }
  }
  return result;
}

ParsedVpnServer? _parseShareLink(String link, Set<String> usedNames) {
  final scheme = link.split('://').first.toLowerCase();
  switch (scheme) {
    case 'vless':
      return _parseVless(link, usedNames);
    case 'vmess':
      return _parseVmess(link, usedNames);
    case 'trojan':
      return _parseTrojan(link, usedNames);
    case 'ss':
      return _parseShadowsocks(link, usedNames);
    case 'hysteria2':
    case 'hy2':
      return _parseHysteria2(link, usedNames);
    case 'hysteria':
      return _parseHysteria(link, usedNames);
    case 'tuic':
      return _parseTuic(link, usedNames);
    case 'anytls':
      return _parseAnytls(link, usedNames);
    case 'socks5':
    case 'socks':
      return _parseSocks5(link, usedNames);
    case 'http':
    case 'https':
      return _parseHttpProxy(link, usedNames);
    default:
      return null;
  }
}

/// Parses `socks5://user:pass@host:port#remark`.
///
/// Remnawave hands these out for the "socks" inbound type, and they are also the
/// simplest way to point the client at a plain local proxy, so the parser must
/// not drop them.
ParsedVpnServer? _parseSocks5(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  final credentials = Uri.decodeComponent(parts.userInfo);
  final separator = credentials.indexOf(':');
  final username = separator < 0 ? credentials : credentials.substring(0, separator);
  final password = separator < 0 ? '' : credentials.substring(separator + 1);

  final proxy = <String, dynamic>{
    'name': '',
    'type': 'socks5',
    'server': parts.host,
    'port': parts.port,
    'udp': true,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
    if (parts.query['skip-cert-verify'] == '1') 'skip-cert-verify': true,
  };
  if (parts.query['tls'] == '1') proxy['tls'] = true;

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'socks5',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

/// Parses `http://user:pass@host:port#remark` into an HTTP CONNECT proxy.
ParsedVpnServer? _parseHttpProxy(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  final credentials = Uri.decodeComponent(parts.userInfo);
  final separator = credentials.indexOf(':');
  final username = separator < 0 ? credentials : credentials.substring(0, separator);
  final password = separator < 0 ? '' : credentials.substring(separator + 1);

  final proxy = <String, dynamic>{
    'name': '',
    'type': 'http',
    'server': parts.host,
    'port': parts.port,
    'tls': link.toLowerCase().startsWith('https://'),
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
  };

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'http',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

/// Splits `scheme://userinfo@host:port?query#fragment` into its parts without
/// relying on [Uri]'s stricter parser, which rejects some real-world links
/// (unencoded `#` inside remarks, IPv6 brackets in unusual positions, …).
({
  String userInfo,
  String host,
  int port,
  Map<String, String> query,
  String remark,
})? _splitLink(String link) {
  final schemeEnd = link.indexOf('://');
  if (schemeEnd < 0) return null;
  var rest = link.substring(schemeEnd + 3);

  var remark = '';
  final hashIndex = rest.indexOf('#');
  if (hashIndex >= 0) {
    remark = Uri.decodeComponent(rest.substring(hashIndex + 1));
    rest = rest.substring(0, hashIndex);
  }

  var query = <String, String>{};
  final queryIndex = rest.indexOf('?');
  if (queryIndex >= 0) {
    final rawQuery = rest.substring(queryIndex + 1);
    rest = rest.substring(0, queryIndex);
    query = Uri.splitQueryString(rawQuery);
  }

  var userInfo = '';
  final atIndex = rest.lastIndexOf('@');
  if (atIndex >= 0) {
    userInfo = rest.substring(0, atIndex);
    rest = rest.substring(atIndex + 1);
  }

  // Host may be an IPv6 literal in brackets.
  String host;
  String portPart;
  if (rest.startsWith('[')) {
    final close = rest.indexOf(']');
    if (close < 0) return null;
    host = rest.substring(1, close);
    final after = rest.substring(close + 1);
    portPart = after.startsWith(':') ? after.substring(1) : '';
  } else {
    final colon = rest.lastIndexOf(':');
    if (colon < 0) {
      host = rest;
      portPart = '';
    } else {
      host = rest.substring(0, colon);
      portPart = rest.substring(colon + 1);
    }
  }
  host = host.trim();
  if (host.isEmpty) return null;
  final port = int.tryParse(portPart.trim()) ?? 0;
  return (
    userInfo: userInfo,
    host: host,
    port: port,
    query: query,
    remark: remark,
  );
}

ParsedVpnServer? _parseVless(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  final security = (parts.query['security'] ?? 'none').toLowerCase();
  final network = (parts.query['type'] ?? 'tcp').toLowerCase();
  final headerType = (parts.query['headerType'] ?? '').toLowerCase();
  final proxy = <String, dynamic>{
    'name': '',
    'type': 'vless',
    'server': parts.host,
    'port': parts.port,
    'uuid': Uri.decodeComponent(parts.userInfo),
    'udp': true,
    'network': network == 'raw' ? 'tcp' : network,
  };
  if (security == 'tls' || security == 'reality' || security == 'xtls') {
    proxy['tls'] = true;
  }
  final sni = parts.query['sni'] ?? parts.query['peer'] ?? '';
  if (sni.isNotEmpty) proxy['servername'] = sni;
  final flow = parts.query['flow'] ?? '';
  if (flow.isNotEmpty) proxy['flow'] = flow;
  final fingerprint = parts.query['fp'] ?? '';
  if (fingerprint.isNotEmpty) proxy['client-fingerprint'] = fingerprint;
  final alpn = parts.query['alpn'] ?? '';
  if (alpn.isNotEmpty) proxy['alpn'] = alpn.split(',');
  if (security == 'reality') {
    final pbk = parts.query['pbk'] ?? '';
    final sid = parts.query['sid'] ?? '';
    if (pbk.isNotEmpty || sid.isNotEmpty) {
      proxy['reality-opts'] = {
        if (pbk.isNotEmpty) 'public-key': pbk,
        if (sid.isNotEmpty) 'short-id': sid,
      };
    }
    proxy['client-fingerprint'] =
        fingerprint.isNotEmpty ? fingerprint : 'chrome';
  }
  if (parts.query['allowInsecure'] == '1' ||
      parts.query['insecure'] == '1') {
    proxy['skip-cert-verify'] = true;
  }
  switch (network) {
    case 'ws':
    case 'httpupgrade':
    case 'xhttp':
      proxy['ws-opts'] = {
        'path': parts.query['path'] ?? '/',
        if ((parts.query['host'] ?? '').isNotEmpty)
          'headers': {'Host': parts.query['host']!},
      };
      if (network == 'httpupgrade') proxy['network'] = 'ws';
      if (network == 'xhttp') proxy['network'] = 'ws';
    case 'grpc':
      final service = parts.query['serviceName'] ?? '';
      proxy['grpc-opts'] = {
        if (service.isNotEmpty) 'grpc-service-name': service,
      };
    case 'tcp':
      if (headerType == 'http') {
        proxy['network'] = 'http';
      }
  }

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'vless',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

ParsedVpnServer? _parseVmess(String link, Set<String> usedNames) {
  // vmess://<base64 of a JSON object>
  final payload = link.substring('vmess://'.length).trim();
  final decoded = _tryDecodeBase64(payload);
  if (decoded == null) return null;
  final dynamic doc = jsonDecode(decoded);
  if (doc is! Map) return null;
  final map = _stringKeyedMap(doc);

  final host = map['add']?.toString() ?? '';
  final port = _asInt(map['port']);
  if (host.isEmpty || port <= 0) return null;

  var security = map['scy']?.toString() ?? map['security']?.toString() ?? 'auto';
  if (security.isEmpty || security == 'none') security = 'auto';
  final network = (map['net']?.toString() ?? 'tcp').toLowerCase();
  final tls = (map['tls']?.toString() ?? '').toLowerCase();

  final proxy = <String, dynamic>{
    'name': '',
    'type': 'vmess',
    'server': host,
    'port': port,
    'uuid': map['id']?.toString() ?? '',
    'alterId': _asInt(map['aid']),
    'cipher': security,
    'udp': true,
    'network': network == 'h2' ? 'h2' : network,
  };
  if (tls == 'tls' || tls == 'reality') proxy['tls'] = true;
  final sni = map['sni']?.toString() ?? '';
  if (sni.isNotEmpty) {
    proxy['servername'] = sni;
  } else if ((map['host']?.toString() ?? '').isNotEmpty) {
    proxy['servername'] = map['host'].toString().split(',').first;
  }
  final alpn = map['alpn']?.toString() ?? '';
  if (alpn.isNotEmpty) proxy['alpn'] = alpn.split(',');

  switch (network) {
    case 'ws':
      proxy['ws-opts'] = {
        'path': map['path']?.toString().isNotEmpty == true
            ? map['path'].toString()
            : '/',
        if (map['host']?.toString().isNotEmpty == true)
          'headers': {'Host': map['host'].toString()},
      };
    case 'grpc':
      final service = map['path']?.toString() ?? '';
      proxy['grpc-opts'] = {
        if (service.isNotEmpty) 'grpc-service-name': service,
      };
    case 'h2':
      proxy['h2-opts'] = {
        if (map['host']?.toString().isNotEmpty == true)
          'host': map['host'].toString().split(','),
        if (map['path']?.toString().isNotEmpty == true)
          'path': map['path'].toString(),
      };
  }

  final rawName = map['ps']?.toString() ?? '';
  final name = _uniqueName(
    rawName.isNotEmpty ? rawName : '$host:$port',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'vmess',
    server: host,
    port: port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

ParsedVpnServer? _parseTrojan(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  final network = (parts.query['type'] ?? 'tcp').toLowerCase();
  final proxy = <String, dynamic>{
    'name': '',
    'type': 'trojan',
    'server': parts.host,
    'port': parts.port,
    'password': Uri.decodeComponent(parts.userInfo),
    'udp': true,
    'network': network == 'raw' ? 'tcp' : network,
  };
  final sni = parts.query['sni'] ?? parts.query['peer'] ?? '';
  if (sni.isNotEmpty) proxy['sni'] = sni;
  final alpn = parts.query['alpn'] ?? '';
  if (alpn.isNotEmpty) proxy['alpn'] = alpn.split(',');
  if (parts.query['allowInsecure'] == '1') proxy['skip-cert-verify'] = true;
  if (network == 'ws') {
    proxy['ws-opts'] = {
      'path': parts.query['path'] ?? '/',
      if ((parts.query['host'] ?? '').isNotEmpty)
        'headers': {'Host': parts.query['host']!},
    };
  } else if (network == 'grpc') {
    final service = parts.query['serviceName'] ?? '';
    proxy['grpc-opts'] = {
      if (service.isNotEmpty) 'grpc-service-name': service,
    };
  }

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'trojan',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

ParsedVpnServer? _parseShadowsocks(String link, Set<String> usedNames) {
  // Two shapes exist: ss://base64(method:password)@host:port#remark and
  // ss://base64(method:password@host:port)#remark (legacy, fully encoded).
  var body = link.substring('ss://'.length);
  var remark = '';
  final hashIndex = body.indexOf('#');
  if (hashIndex >= 0) {
    remark = Uri.decodeComponent(body.substring(hashIndex + 1));
    body = body.substring(0, hashIndex);
  }
  var query = <String, String>{};
  final queryIndex = body.indexOf('?');
  if (queryIndex >= 0) {
    query = Uri.splitQueryString(body.substring(queryIndex + 1));
    body = body.substring(0, queryIndex);
  }

  String method;
  String password;
  String host;
  int port;

  final atIndex = body.lastIndexOf('@');
  if (atIndex < 0) {
    final decoded = _tryDecodeBase64(body);
    if (decoded == null) return null;
    final decodedAt = decoded.lastIndexOf('@');
    if (decodedAt < 0) return null;
    final creds = decoded.substring(0, decodedAt);
    final endpoint = decoded.substring(decodedAt + 1);
    final split = creds.indexOf(':');
    if (split < 0) return null;
    method = creds.substring(0, split);
    password = creds.substring(split + 1);
    final colon = endpoint.lastIndexOf(':');
    if (colon < 0) return null;
    host = endpoint.substring(0, colon);
    port = int.tryParse(endpoint.substring(colon + 1)) ?? 0;
  } else {
    final credsEncoded = body.substring(0, atIndex);
    var creds = credsEncoded;
    if (!creds.contains(':')) {
      creds = _tryDecodeBase64(credsEncoded) ?? credsEncoded;
    } else {
      // Some generators leave the password percent-encoded.
      creds = Uri.decodeComponent(credsEncoded);
    }
    final split = creds.indexOf(':');
    if (split < 0) return null;
    method = creds.substring(0, split);
    password = creds.substring(split + 1);
    final endpoint = body.substring(atIndex + 1);
    final colon = endpoint.lastIndexOf(':');
    if (colon < 0) return null;
    host = endpoint.substring(0, colon);
    port = int.tryParse(endpoint.substring(colon + 1)) ?? 0;
  }
  if (host.isEmpty || port <= 0 || method.isEmpty) return null;

  final proxy = <String, dynamic>{
    'name': '',
    'type': 'ss',
    'server': host,
    'port': port,
    'cipher': method.toLowerCase(),
    'password': password,
    'udp': true,
  };
  if ((query['plugin'] ?? '').isNotEmpty) {
    final plugin = query['plugin']!;
    final segments = plugin.split(';');
    final pluginName = segments.first;
    final opts = <String, String>{};
    for (final segment in segments.skip(1)) {
      final eq = segment.indexOf('=');
      if (eq < 0) {
        opts[segment] = 'true';
      } else {
        opts[segment.substring(0, eq)] = segment.substring(eq + 1);
      }
    }
    if (pluginName.startsWith('obfs')) {
      proxy['plugin'] = 'obfs';
      proxy['plugin-opts'] = {
        'mode': opts['obfs'] ?? 'http',
        'host': opts['obfs-host'] ?? '',
      };
    } else if (pluginName.startsWith('v2ray-plugin')) {
      proxy['plugin'] = 'v2ray-plugin';
      proxy['plugin-opts'] = {
        'mode': opts['mode'] ?? 'websocket',
        'host': opts['host'] ?? '',
        'path': opts['path'] ?? '/',
        if (opts.containsKey('tls')) 'tls': true,
      };
    }
  }

  final name = _uniqueName(
    remark.isNotEmpty ? remark : '$host:$port',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'ss',
    server: host,
    port: port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

ParsedVpnServer? _parseHysteria2(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  // hysteria2://auth@host:port?sni=…
  var auth = Uri.decodeComponent(parts.userInfo);
  final colon = auth.indexOf(':');
  if (colon >= 0) auth = auth.substring(colon + 1);
  final proxy = <String, dynamic>{
    'name': '',
    'type': 'hysteria2',
    'server': parts.host,
    'port': parts.port,
    'password': auth,
  };
  final sni = parts.query['sni'] ?? parts.query['peer'] ?? '';
  if (sni.isNotEmpty) proxy['sni'] = sni;
  if (parts.query['insecure'] == '1' ||
      parts.query['allowInsecure'] == '1') {
    proxy['skip-cert-verify'] = true;
  }
  if ((parts.query['obfs'] ?? '').isNotEmpty) {
    proxy['obfs'] = parts.query['obfs'];
    proxy['obfs-password'] = parts.query['obfs-password'] ?? '';
  }
  final alpn = parts.query['alpn'] ?? '';
  if (alpn.isNotEmpty) proxy['alpn'] = alpn.split(',');
  if ((parts.query['mport'] ?? '').isNotEmpty) {
    proxy['ports'] = parts.query['mport'];
  }

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'hysteria2',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

ParsedVpnServer? _parseHysteria(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  final proxy = <String, dynamic>{
    'name': '',
    'type': 'hysteria',
    'server': parts.host,
    'port': parts.port,
    'auth-str': parts.query['auth'] ?? Uri.decodeComponent(parts.userInfo),
    'protocol': parts.query['protocol'] ?? 'udp',
    'up': parts.query['upmbps'] ?? '50',
    'down': parts.query['downmbps'] ?? '100',
  };
  final sni = parts.query['peer'] ?? parts.query['sni'] ?? '';
  if (sni.isNotEmpty) proxy['sni'] = sni;
  final alpn = parts.query['alpn'] ?? '';
  if (alpn.isNotEmpty) proxy['alpn'] = alpn.split(',');
  if (parts.query['insecure'] == '1') proxy['skip-cert-verify'] = true;

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'hysteria',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

ParsedVpnServer? _parseTuic(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  final creds = Uri.decodeComponent(parts.userInfo);
  final split = creds.indexOf(':');
  final uuid = split >= 0 ? creds.substring(0, split) : creds;
  final password = split >= 0 ? creds.substring(split + 1) : '';
  final proxy = <String, dynamic>{
    'name': '',
    'type': 'tuic',
    'server': parts.host,
    'port': parts.port,
    'uuid': uuid,
    'password': password,
    'udp-relay-mode': parts.query['udp_relay_mode'] ?? 'native',
    'congestion-controller': parts.query['congestion_control'] ?? 'bbr',
  };
  final sni = parts.query['sni'] ?? '';
  if (sni.isNotEmpty) proxy['sni'] = sni;
  final alpn = parts.query['alpn'] ?? '';
  if (alpn.isNotEmpty) proxy['alpn'] = alpn.split(',');
  if (parts.query['allow_insecure'] == '1') proxy['skip-cert-verify'] = true;

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'tuic',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

ParsedVpnServer? _parseAnytls(String link, Set<String> usedNames) {
  final parts = _splitLink(link);
  if (parts == null || parts.port <= 0) return null;
  final proxy = <String, dynamic>{
    'name': '',
    'type': 'anytls',
    'server': parts.host,
    'port': parts.port,
    'password': Uri.decodeComponent(parts.userInfo),
    'udp': true,
  };
  final sni = parts.query['sni'] ?? '';
  if (sni.isNotEmpty) proxy['sni'] = sni;
  if (parts.query['insecure'] == '1') proxy['skip-cert-verify'] = true;

  final name = _uniqueName(
    parts.remark.isNotEmpty ? parts.remark : '${parts.host}:${parts.port}',
    usedNames,
  );
  proxy['name'] = name;
  return ParsedVpnServer(
    remark: name,
    protocol: 'anytls',
    server: parts.host,
    port: parts.port,
    proxy: proxy,
    countryCode: _countryFromRemark(name),
  );
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

String? _tryDecodeBase64(String value) {
  var candidate = value.replaceAll(RegExp(r'\s'), '');
  if (candidate.isEmpty) return null;
  // URL-safe variant used by some panels.
  candidate = candidate.replaceAll('-', '+').replaceAll('_', '/');
  final pad = candidate.length % 4;
  if (pad == 2) {
    candidate += '==';
  } else if (pad == 3) {
    candidate += '=';
  } else if (pad == 1) {
    return null;
  }
  try {
    final bytes = base64.decode(candidate);
    final decoded = utf8.decode(bytes, allowMalformed: true);
    return decoded.isEmpty ? null : decoded;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _stringKeyedMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _uniqueName(String name, Set<String> used) {
  var candidate = name.trim();
  if (candidate.isEmpty) candidate = 'Server';
  if (used.add(candidate)) return candidate;
  var index = 2;
  while (!used.add('$candidate #$index')) {
    index++;
  }
  return '$candidate #$index';
}

/// Extracts an ISO-3166 alpha-2 code from a remark when the panel embeds a
/// regional indicator pair, e.g. `🇩🇪 Germany`. Falls back to common country
/// names so the UI can still show something useful.
String? _countryFromRemark(String remark) {
  final runes = remark.runes.toList();
  for (var i = 0; i < runes.length - 1; i++) {
    final first = runes[i];
    final second = runes[i + 1];
    if (first >= 0x1F1E6 &&
        first <= 0x1F1FF &&
        second >= 0x1F1E6 &&
        second <= 0x1F1FF) {
      final a = String.fromCharCode(first - 0x1F1E6 + 0x41);
      final b = String.fromCharCode(second - 0x1F1E6 + 0x41);
      return '$a$b';
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Minimal YAML reader
// ---------------------------------------------------------------------------

/// Exposed for the development harness (`tool/smoke_core.dart`): shows exactly
/// what the mini-YAML reader understood, without going through protocol
/// mapping. Not used by the application.
dynamic debugParseYaml(String source) => _loadYamlQuietly(source);

/// A deliberately small YAML subset parser.
///
/// Remnawave emits profiles built from block mappings, block sequences and
/// quoted/unquoted scalars, which is exactly what this covers. It is not a
/// general YAML implementation and makes no attempt to be one: anything it
/// cannot understand is skipped rather than guessed, and the share-link and
/// JSON paths remain available as fallbacks.
class _MiniYaml {
  static dynamic parse(String source) {
    final lines = <_YamlLine>[];
    for (final raw in source.split('\n')) {
      final withoutComment = _stripComment(raw);
      if (withoutComment.trim().isEmpty) continue;
      final indent = withoutComment.length -
          withoutComment.replaceFirst(RegExp(r'^ *'), '').length;
      // Tabs are illegal in YAML indentation; normalise defensively.
      final content = withoutComment.trim().replaceAll('\t', '  ');
      if (content.startsWith('%') || content.startsWith('---')) continue;
      lines.add(_YamlLine(indent, content));
    }
    if (lines.isEmpty) return null;
    final cursor = _Cursor(lines);
    return _parseBlock(cursor, lines.first.indent);
  }

  static String _stripComment(String line) {
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (char == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (char == '#' && !inSingle && !inDouble) {
        if (i == 0 || line[i - 1] == ' ') {
          return line.substring(0, i);
        }
      }
    }
    return line;
  }

  /// Parses the block that follows a bare `key:`, a bare `-`, or a mapping key
  /// with no inline value.
  ///
  /// The nested block may be indented by any amount greater than [parentIndent]
  /// — real profiles use two spaces, but nothing in YAML requires exactly one
  /// more level, so the indent is taken from the first line of the block.
  static dynamic _parseNested(_Cursor cursor, int parentIndent) {
    if (cursor.atEnd) return null;
    final line = cursor.peek!;
    if (line.indent <= parentIndent) return null;
    return _parseBlock(cursor, line.indent);
  }

  static dynamic _parseBlock(_Cursor cursor, int indent) {
    if (cursor.atEnd) return null;
    final line = cursor.peek!;
    if (line.indent < indent) return null;
    final isSequence = line.content.startsWith('- ') || line.content == '-';
    return isSequence
        ? _parseSequence(cursor, indent)
        : _parseMapping(cursor, indent);
  }

  static List<dynamic> _parseSequence(_Cursor cursor, int indent) {
    final result = <dynamic>[];
    while (!cursor.atEnd) {
      final line = cursor.peek!;
      if (line.indent != indent) break;
      if (!line.content.startsWith('-')) break;
      cursor.next();
      final remainder = line.content.substring(1).trim();
      if (remainder.isEmpty) {
        // `-` on its own line: the item is the nested block that follows.
        result.add(_parseNested(cursor, indent));
        continue;
      }
      // `- key: value` opens an inline mapping whose sibling keys are indented
      // relative to the line itself, exactly like any other block mapping.
      final inlineMap = _tryInlineMapping(remainder);
      if (inlineMap == null) {
        result.add(_parseScalar(remainder));
        continue;
      }
      final entryIndent = indent + (line.content.length - remainder.length);
      final map = <String, dynamic>{};
      if (inlineMap.value == null) {
        map[inlineMap.key] = _parseNested(cursor, entryIndent);
      } else {
        map[inlineMap.key] = inlineMap.value;
      }
      while (!cursor.atEnd) {
        final next = cursor.peek!;
        if (next.indent != entryIndent) break;
        if (next.content.startsWith('-')) break;
        final sibling = _tryInlineMapping(next.content);
        if (sibling == null) break;
        cursor.next();
        if (sibling.value == null) {
          map[sibling.key] = _parseNested(cursor, entryIndent);
        } else {
          map[sibling.key] = sibling.value;
        }
      }
      result.add(map);
    }
    return result;
  }

  static Map<String, dynamic> _parseMapping(_Cursor cursor, int indent) {
    final result = <String, dynamic>{};
    while (!cursor.atEnd) {
      final line = cursor.peek!;
      if (line.indent != indent) break;
      if (line.content.startsWith('-')) break;
      final entry = _tryInlineMapping(line.content);
      if (entry == null) break;
      cursor.next();
      if (entry.value == null) {
        result[entry.key] = _parseNested(cursor, indent);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  static ({String key, dynamic value})? _tryInlineMapping(String content) {
    // Find a `key:` that is not inside quotes.
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < content.length; i++) {
      final char = content[i];
      if (char == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (char == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (char == ':' && !inSingle && !inDouble) {
        final isLast = i == content.length - 1;
        final nextIsSpace = !isLast && content[i + 1] == ' ';
        if (isLast || nextIsSpace) {
          final key = _unquote(content.substring(0, i).trim());
          final rawValue = isLast ? '' : content.substring(i + 1).trim();
          if (rawValue.isEmpty) return (key: key, value: null);
          // `key: {a: b}` / `key: [a, b]` flow collections.
          final flow = _tryFlowCollection(rawValue);
          return (key: key, value: flow ?? _parseScalar(rawValue));
        }
      }
    }
    return null;
  }

  static dynamic _tryFlowCollection(String value) {
    if (value.startsWith('{') && value.endsWith('}')) {
      final inner = value.substring(1, value.length - 1).trim();
      final map = <String, dynamic>{};
      if (inner.isEmpty) return map;
      for (final pair in _splitTopLevel(inner, ',')) {
        final entry = _tryInlineMapping(pair.trim());
        if (entry != null) map[entry.key] = entry.value;
      }
      return map;
    }
    if (value.startsWith('[') && value.endsWith(']')) {
      final inner = value.substring(1, value.length - 1).trim();
      if (inner.isEmpty) return <dynamic>[];
      return _splitTopLevel(inner, ',')
          .map((item) => _parseScalar(item.trim()))
          .toList();
    }
    return null;
  }

  static List<String> _splitTopLevel(String value, String separator) {
    final result = <String>[];
    var depth = 0;
    var inSingle = false;
    var inDouble = false;
    final buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (char == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (char == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (!inSingle && !inDouble) {
        if (char == '{' || char == '[') depth++;
        if (char == '}' || char == ']') depth--;
        if (char == separator && depth == 0) {
          result.add(buffer.toString());
          buffer.clear();
          continue;
        }
      }
      buffer.write(char);
    }
    if (buffer.isNotEmpty) result.add(buffer.toString());
    return result;
  }

  static dynamic _parseScalar(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final unquoted = _unquote(value);
    if (unquoted != value || value.startsWith("'") || value.startsWith('"')) {
      return unquoted;
    }
    final lower = value.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
    if (lower == 'null' || lower == '~') return null;
    final asInt = int.tryParse(value);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(value);
    if (asDouble != null) return asDouble;
    final flow = _tryFlowCollection(value);
    if (flow != null) return flow;
    return value;
  }

  static String _unquote(String value) {
    if (value.length >= 2) {
      if (value.startsWith('"') && value.endsWith('"')) {
        final inner = value.substring(1, value.length - 1);
        return inner
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\"', '"')
            .replaceAll(r'\\', r'\');
      }
      if (value.startsWith("'") && value.endsWith("'")) {
        return value.substring(1, value.length - 1).replaceAll("''", "'");
      }
    }
    return value;
  }
}

class _YamlLine {
  _YamlLine(this.indent, this.content);

  final int indent;
  final String content;
}

class _Cursor {
  _Cursor(this._lines);

  final List<_YamlLine> _lines;
  int _index = 0;

  bool get atEnd => _index >= _lines.length;

  _YamlLine? get peek => atEnd ? null : _lines[_index];

  void next() => _index++;
}

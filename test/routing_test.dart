import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/core/bypass_domains.dart';
import 'package:scaleguard_mobile/core/mihomo_config.dart';
import 'package:scaleguard_mobile/core/subscription_parser.dart';
import 'package:scaleguard_mobile/core/vpn_engine.dart';

/// Checks on the routing rules the connection settings produce.
///
/// The rules are the whole point of the client's three decisions: a domain the
/// user named that must leave through the location, a tracker that must be cut
/// off, and a Russian service that must keep the user's own address. Which of
/// them wins when two of them match is
/// decided by their order in the generated profile, and that order is the one
/// thing a wrong edit would silently break — a later rule simply never runs, and
/// nothing in the application would notice.
void main() {
  ParsedVpnServer server(String name) => ParsedVpnServer(
        remark: name,
        protocol: 'vless',
        server: '198.51.100.10',
        port: 443,
        proxy: <String, dynamic>{'name': name, 'type': 'vless'},
      );

  String build({
    List<String> bypassDomains = const <String>[],
    bool ruDirect = true,
    bool gameMode = false,
    VpnTunnelMode mode = VpnTunnelMode.systemProxy,
    TunAddresses? tunAddresses,
  }) {
    return MihomoConfigBuilder().build(
      MihomoConfigOptions(
        servers: <ParsedVpnServer>[server('🇩🇪 Германия | #1')],
        mixedPort: 17890,
        controllerPort: 19090,
        secret: 'secret',
        mode: mode,
        gameMode: gameMode,
        bypassDomains: bypassDomains,
        ruDirect: ruDirect,
        tunAddresses: tunAddresses,
      ),
    );
  }

  group('parsing what the user typed', () {
    test('accepts the shape the field advertises', () {
      expect(
        parseBypassDomains('123.com, https://www.youtube.com,sakyr.org'),
        <String>['123.com', 'youtube.com', 'sakyr.org'],
      );
    });

    test('reduces a full URL to the domain behind it', () {
      expect(
        parseBypassDomains('https://WWW.YouTube.com/watch?v=abc#frag'),
        <String>['youtube.com'],
      );
      expect(parseBypassDomains('http://example.org:8443/path'), <String>['example.org']);
    });

    test('splits on whitespace and newlines as well as commas', () {
      expect(
        parseBypassDomains('a.com b.com\nc.com;d.com'),
        <String>['a.com', 'b.com', 'c.com', 'd.com'],
      );
    });

    test('drops duplicates and keeps the first spelling', () {
      expect(
        parseBypassDomains('youtube.com, www.youtube.com, YOUTUBE.COM'),
        <String>['youtube.com'],
      );
    });

    test('keeps addresses that are not domains', () {
      expect(parseBypassDomains('203.0.113.7'), <String>['203.0.113.7']);
    });

    test('refuses entries that are not hosts at all', () {
      expect(parseBypassDomains('   , , not a host, ***, localhost'),
          isEmpty);
    });

    test('never returns more than the store can hold', () {
      final many = List<String>.generate(400, (index) => 'site$index.com');
      expect(parseBypassDomains(many.join(',')).length, maxBypassDomains);
    });

    test('renders back the form the field shows', () {
      expect(formatBypassDomains(<String>['a.com', 'b.com']), 'a.com, b.com');
    });
  });

  group('user list of sites that must go through the location', () {
    test('is a proxy rule for the domain and its subdomains', () {
      final config = build(bypassDomains: <String>['youtube.com']);
      expect(config, contains('  - DOMAIN-SUFFIX,youtube.com,PROXY'));
    });

    test('handles a bare address as a range instead of a domain', () {
      final config = build(bypassDomains: <String>['203.0.113.7']);
      expect(
        config,
        contains('  - IP-CIDR,203.0.113.7/32,PROXY,no-resolve'),
      );
      expect(config, isNot(contains('DOMAIN-SUFFIX,203.0.113.7')));
    });

    test('is applied in both modes', () {
      for (final mode in VpnTunnelMode.values) {
        expect(
          build(bypassDomains: <String>['sakyr.org'], mode: mode),
          contains('  - DOMAIN-SUFFIX,sakyr.org,PROXY'),
          reason: 'missing in ${mode.name}',
        );
      }
    });

    test('outranks the Russian zone rules', () {
      // The whole point of the list: a Russian service named by the user leaves
      // through the location even though the zone rule below keeps it direct.
      final russian = build(bypassDomains: <String>['sberbank.ru']);
      expect(
        russian.indexOf('DOMAIN-SUFFIX,sberbank.ru,PROXY'),
        lessThan(russian.indexOf('DOMAIN-SUFFIX,sberbank.ru,DIRECT')),
      );
    });

    test('comes before the catch-all that would proxy it', () {
      final config = build(bypassDomains: <String>['youtube.com']);
      expect(
        config.indexOf('DOMAIN-SUFFIX,youtube.com,PROXY'),
        lessThan(config.indexOf('- MATCH,PROXY')),
      );
    });
  });

  group('advertising filter', () {
    test('is gone: no domain is rejected any more', () {
      final config = build();
      // The list- and resolver-based blockers were removed on purpose: the
      // second one broke name resolution on networks where its DoH endpoint was
      // unreachable, and neither can remove an advertisement from an
      // application that is served its ads from the same CDN as its content
      // (YouTube), so what was left was the breakage without the benefit.
      expect(config, isNot(contains('REJECT')));
      expect(config, isNot(contains('dns.adguard-dns.com')));
      expect(config, contains('https://1.1.1.1/dns-query'));
    });
  });

  group('Russian services', () {
    test('are kept on the real connection by default', () {
      final config = build();
      expect(config, contains('  - DOMAIN-SUFFIX,sberbank.ru,DIRECT'));
      expect(config, contains('  - DOMAIN-SUFFIX,gosuslugi.ru,DIRECT'));
      expect(config, contains('  - DOMAIN-SUFFIX,ru,DIRECT'));
    });

    test('cover the banking apps that live outside the .ru zone', () {
      final config = build();
      expect(config, contains('  - DOMAIN-SUFFIX,sberbank.com,DIRECT'));
      expect(config, contains('  - DOMAIN-SUFFIX,vk.com,DIRECT'));
      expect(config, contains('  - DOMAIN-SUFFIX,yandex.net,DIRECT'));
      // `.рф` only matches after the IDN conversion the core performs.
      expect(config, contains('  - DOMAIN-SUFFIX,xn--p1ai,DIRECT'));
    });

    test('are routed before the catch-all', () {
      final config = build();
      expect(
        config.indexOf('DOMAIN-SUFFIX,ru,DIRECT'),
        lessThan(config.indexOf('- MATCH,PROXY')),
      );
    });

    test('do not depend on game mode any more', () {
      expect(build(ruDirect: true), contains('DOMAIN-SUFFIX,gosuslugi.ru,DIRECT'));
      expect(
        build(gameMode: true),
        contains('DOMAIN-SUFFIX,gosuslugi.ru,DIRECT'),
      );
    });

    test('are also routed by address, not only by name', () {
      final config = build();
      // A `.com` API of a Russian bank is invisible to a suffix rule; its
      // address is not.
      expect(config, contains('  - IP-CIDR,2.56.24.0/22,DIRECT'));
      expect(
        config.indexOf('  - IP-CIDR,2.56.24.0/22,DIRECT'),
        lessThan(config.indexOf('- MATCH,PROXY')),
      );
      expect(
        build(ruDirect: false),
        isNot(contains('  - IP-CIDR,2.56.24.0/22,DIRECT')),
      );
    });

    test('disappear when the user turns them off', () {
      final config = build(ruDirect: false);
      expect(config, isNot(contains('DOMAIN-SUFFIX,ru,DIRECT')));
      expect(config, isNot(contains('DOMAIN-SUFFIX,gosuslugi.ru,DIRECT')));
      // The catch-all is still what carries everything else.
      expect(config, contains('- MATCH,PROXY'));
    });
  });

  group('the tunnel adapter', () {
    test('announces its addresses as sequences', () {
      final config = build(
        mode: VpnTunnelMode.tun,
        tunAddresses: const TunAddresses(
          v4: '172.19.0.1/30',
          v6: 'fdfe:dcba:9876:1::1/126',
        ),
      );
      // The core reads both keys as lists. A bare scalar is decoded as a string
      // and the whole profile is rejected when it loads, which on Windows looked
      // like a controller that never answered: "cannot unmarshal !!str … into
      // []netip.Prefix".
      expect(config, contains('  inet4-address: [172.19.0.1/30]'));
      expect(config, contains('  inet6-address: [fdfe:dcba:9876:1::1/126]'));
    });

    test('leaves the keys out when the platform owns the interface', () {
      final config = build();
      expect(config, isNot(contains('inet4-address')));
      expect(config, isNot(contains('inet6-address')));
    });
  });

  group('the profile as a whole', () {
    test('keeps the private ranges ahead of every choice', () {
      final config = build(bypassDomains: <String>['youtube.com']);
      expect(
        config.indexOf('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'),
        lessThan(config.indexOf('DOMAIN-SUFFIX,youtube.com,PROXY')),
      );
    });

    test('never ends a rule list without a default route', () {
      expect(build().trimRight(), endsWith('- MATCH,PROXY'));
    });

    test('emits every bundled list exactly once', () {
      final rules = build()
          .split('\n')
          .where((line) => line.startsWith('  - '))
          .toList();
      // The same rule twice is harmless to the core but is a sign the lists
      // were concatenated instead of merged — and it is what a careless edit to
      // one of the const lists above produces.
      final duplicates = <String>[];
      final seen = <String>{};
      for (final rule in rules) {
        if (!seen.add(rule)) duplicates.add(rule);
      }
      expect(duplicates, isEmpty);
    });
  });
}

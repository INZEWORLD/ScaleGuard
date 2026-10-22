import 'dart:convert';

import 'bypass_domains.dart';
import 'ru_cidrs.dart';
import 'subscription_parser.dart';
import 'vpn_engine.dart';

/// Runtime parameters for one generated mihomo profile.
///
/// Ports are chosen by the engine (and probed for availability) so several VPN
/// clients can coexist; everything else is derived from the subscription.
class MihomoConfigOptions {
  MihomoConfigOptions({
    required this.servers,
    required this.mixedPort,
    required this.controllerPort,
    required this.secret,
    required this.mode,
    this.tunDeviceName = 'ScaleGuard',
    this.tunAddresses,
    this.logLevel = 'warning',
    this.cacheDir,
    this.enableIpv6 = false,
    this.bypassLocalNetworks = true,
    this.autoSelectPolicy = const AutoSelectPolicy(),
    this.urlTestUrl = 'https://www.gstatic.com/generate_204',
    this.gameMode = false,
    this.bypassDomains = const <String>[],
    this.ruDirect = true,
  });

  final List<ParsedVpnServer> servers;
  final int mixedPort;
  final int controllerPort;
  final String secret;
  final VpnTunnelMode mode;
  final String tunDeviceName;

  /// Addresses written into the profile's `tun` section.
  ///
  /// `null` leaves them out, which lets the core keep its own defaults — right
  /// wherever the OS configures the interface (Android) or where the profile is
  /// the only client on the machine. Windows passes explicit values because its
  /// defaults belong to every other Clash-family client too.
  final TunAddresses? tunAddresses;

  final String logLevel;
  final String? cacheDir;
  final bool enableIpv6;
  final bool bypassLocalNetworks;

  /// Rules for automatic selection (Russian nodes out, anti-flapping tolerance).
  final AutoSelectPolicy autoSelectPolicy;

  /// Endpoint used for latency probes. It must return 204 without redirects;
  /// `generate_204` is the de-facto standard in the Clash ecosystem.
  final String urlTestUrl;

  /// Games connect directly while everything else stays proxied.
  final bool gameMode;

  /// Domains the user added by hand; they always leave over the real
  /// connection, whatever the rules below would have decided.
  final List<String> bypassDomains;

  /// Keeps Russian services on the user's own connection so their apps — banks
  /// and government portals above all — never see a foreign exit address.
  final bool ruDirect;
}

/// Domains of game platforms and launchers that must bypass the VPN.
///
/// Game traffic goes straight to the provider for latency, and the CDNs stay
/// direct so downloads keep full speed.
const List<String> gameDirectDomains = <String>[
  'steamcommunity.com',
  'steampowered.com',
  'steamstatic.com',
  'steamcontent.com',
  'steamusercontent.com',
  'steamserver.net',
  'epicgames.com',
  'unrealengine.com',
  'riotgames.com',
  'battle.net',
  'blizzard.com',
  'ea.com',
  'origin.com',
  'ubisoft.com',
  'ubi.com',
  'wargaming.net',
  'rockstargames.com',
  'gog.com',
  'mojang.com',
  'minecraft.net',
  'minecraftservices.com',
  'playstation.com',
  'playstation.net',
  'xbox.com',
  'xboxlive.com',
  'nintendo.com',
  'nintendo.net',
  'roblox.com',
  'rbxcdn.com',
  'faceit.com',
];

/// Executables that belong to game clients, matched by process name.
///
/// Domain rules alone are not enough for "games go direct": in TUN mode the
/// core also sees the game's own traffic, which arrives as a bare IP address and
/// therefore never matches a `DOMAIN-SUFFIX` rule. Matching the process catches
/// exactly that traffic, whatever destination it is heading for.
///
/// Only used in game mode, and only on a core that can see process names — a
/// failed lookup simply leaves the connection on the default route, so the list
/// can never break anything.
const List<String> gameProcessNames = <String>[
  // Valve / Source
  'cs2.exe',
  'dota2.exe',
  'hl2.exe',
  'left4dead2.exe',
  'garrysmod.exe',
  // Riot / Blizzard / Activision
  'valorant.exe',
  'valorant-win64-shipping.exe',
  'leagueclient.exe',
  'leagueclientux.exe',
  'league of legends.exe',
  'overwatch.exe',
  'battle.net.exe',
  'modernwarfare.exe',
  'cod.exe',
  'warzone.exe',
  // Epic / Unreal
  'fortniteclient-win64-shipping.exe',
  'rocketleague.exe',
  // EA / Ubisoft / Wargaming
  'ea app.exe',
  'bf2042.exe',
  'rainbowsix.exe',
  'rainbow6.exe',
  'rainbow6dx11.exe',
  'rainbow6dx12.exe',
  'rainbow6vulkan.exe',
  'worldoftanks.exe',
  'worldofwarplanes.exe',
  'wows.exe',
  // Rockstar / Take-Two
  'gta5.exe',
  'rdr2.exe',
  // Battle royale / shooters
  'r5apex.exe',
  'pubg.exe',
  'tslgame.exe',
  'escapefromtarkov.exe',
  'dayz_x64.exe',
  'dayz.exe',
  'scum.exe',
  'rustclient.exe',
  // MMO / RPG / co-op
  'ffxiv_dx11.exe',
  'ffxiv.exe',
  'wow.exe',
  'wowclassic.exe',
  'eldenring.exe',
  'cyberpunk2077.exe',
  'witcher3.exe',
  'palworld-win64-shipping.exe',
  'stardew valley.exe',
  'terraria.exe',
  'brawlhalla.exe',
  'among us.exe',
  // Minecraft (the JVM wrapper is what actually opens the sockets)
  'minecraft.exe',
  'minecraft.windows.exe',
  'javaw.exe',
  // Mobile ports emulated on desktop and browser clients
  'robloxplayerbeta.exe',
  'genshinimpact.exe',
  'yuanshen.exe',
  'starrail.exe',
];

/// Download clients that must always stay off the tunnel.
///
/// These move gigabytes with no upper bound and no interactive benefit from a
/// foreign exit, so they go out over the user's own connection. The game
/// launchers are included because their store and content downloads share the
/// same processes.
const List<String> bulkDownloadProcessNames = <String>[
  // Torrent clients
  'qbittorrent.exe',
  'qbittorrent-nox.exe',
  'utorrent.exe',
  'bittorrent.exe',
  'bitcomet.exe',
  'bitlord.exe',
  'transmission-qt.exe',
  'transmission-daemon.exe',
  'deluge.exe',
  'tixati.exe',
  'vuze.exe',
  'azureus.exe',
  'frostwire.exe',
  'mediaget.exe',
  'zona.exe',
  // Media and file downloaders
  'aria2c.exe',
  'motrix.exe',
  'thunder.exe',
  'free-download-manager.exe',
  'fdm.exe',
  'jdownloader.jar',
  'jd2.exe',
  // Game stores and launchers: downloads, patches and content caches
  'steam.exe',
  'steamwebhelper.exe',
  'steamservice.exe',
  'epicgameslauncher.exe',
  'battle.net.exe',
  'eadesktop.exe',
  'ea app.exe',
  'origin.exe',
  'eabackgroundservice.exe',
  'ubisoftconnect.exe',
  'ubisoftgamelauncher.exe',
  'upc.exe',
  'gog galaxy.exe',
  'galaxyclient.exe',
  'riotclientservices.exe',
  'riotclientux.exe',
  'rockstargameslauncher.exe',
  'wgc.exe',
  'bethesdanetlauncher.exe',
  'playnite.exe',
];

/// Content networks the download clients pull from.
///
/// Matching the executables covers the peer connections; these domains cover
/// the CDN side, which is where a store download actually spends its time.
const List<String> bulkDownloadDomains = <String>[
  // Steam content network
  'steamcontent.com',
  'steamserver.net',
  'steamstatic.com',
  'steampowered.com',
  'steamcommunity.com',
  'steamusercontent.com',
  'steamgames.com',
  'steam-chat.com',
  'steamcdn-a.akamaihd.net',
  'steampipe.akamaized.net',
  'steamcontent-a.akamaihd.net',
  'steamusercontent-a.akamaihd.net',
  // Game stores
  'epicgames.com',
  'unrealengine.com',
  'ea.com',
  'origin.com',
  'ubisoft.com',
  'ubi.com',
  'gog.com',
  'battle.net',
  'blizzard.com',
  'wargaming.net',
  'rockstargames.com',
  'riotgames.com',
  'roblox.com',
  'rbxcdn.com',
  'mojang.com',
  'minecraft.net',
  'minecraftservices.com',
  // Microsoft and Apple delivery networks: OS updates are the same kind of
  // bulk transfer and the same reasoning applies to them.
  'windowsupdate.com',
  'windowsupdate.microsoft.com',
  'update.microsoft.com',
  'download.microsoft.com',
  'delivery.mp.microsoft.com',
  'dl.delivery.mp.microsoft.com',
  'catalog.update.microsoft.com',
  'swcdn.apple.com',
  'updates.cdn-apple.com',
];

/// Russian services that must never leave through the VPN exit.
///
/// The `.ru` zone itself is covered by a suffix rule, so this list only has to
/// name the services that live outside it — which is exactly where the banking
/// and media apps that check the exit address do live.
const List<String> ruDirectDomains = <String>[
  // Mail, social and media
  'yandex.ru',
  'ya.ru',
  'yandex.net',
  'yastatic.net',
  'dzen.ru',
  'kinopoisk.ru',
  'mail.ru',
  'list.ru',
  'bk.ru',
  'inbox.ru',
  'vk.com',
  'vk.ru',
  'vkvideo.ru',
  'userapi.com',
  'ok.ru',
  'rutube.ru',
  'rbc.ru',
  'lenta.ru',
  'gazeta.ru',
  '2gis.ru',
  // Banks and payment systems
  'sberbank.ru',
  'sber.ru',
  'sberbank.com',
  'sbrf.ru',
  'sbol.ru',
  'tinkoff.ru',
  'tbank.ru',
  'tinkoff.com',
  'alfabank.ru',
  'vtb.ru',
  'vtb.com',
  'gazprombank.ru',
  'psbank.ru',
  'rosselhozbank.ru',
  'open.ru',
  'otkritie.ru',
  'raiffeisen.ru',
  'rosbank.ru',
  'sovcombank.ru',
  'homecredit.ru',
  'mkb.ru',
  'unicreditbank.ru',
  'mirconnect.ru',
  'nspk.ru',
  'mironline.ru',
  // Government, taxes and utilities
  'gosuslugi.ru',
  'esia.gosuslugi.ru',
  'nalog.ru',
  'nalog.gov.ru',
  'mos.ru',
  'mosreg.ru',
  'pfr.gov.ru',
  'sfr.gov.ru',
  'rosreestr.ru',
  'gibdd.ru',
  'mvd.ru',
  'mil.ru',
  'russianpost.ru',
  'pochta.ru',
  'mosenergosbyt.ru',
  'zakupki.gov.ru',
  // Carriers and internet providers
  'mts.ru',
  'megafon.ru',
  'beeline.ru',
  'tele2.ru',
  'yota.ru',
  'rt.ru',
  'rostelecom.ru',
  'ertelecom.ru',
  'domru.ru',
  'mgts.ru',
  't2.ru',
  // Shops and delivery
  'wildberries.ru',
  'wbbasket.ru',
  'ozon.ru',
  'avito.ru',
  'dns-shop.ru',
  'mvideo.ru',
  'eldorado.ru',
  'citilink.ru',
  'leroymerlin.ru',
  'vseinstrumenti.ru',
  'detmir.ru',
  'lenta.com',
  'magnit.ru',
  'perekrestok.ru',
  'auchan.ru',
  'x5.ru',
  'pyaterochka.ru',
  'sbermarket.ru',
  'samokat.ru',
  'cdek.ru',
  'dellin.ru',
  'rzd.ru',
  'aeroflot.ru',
  's7.ru',
  'sberbank-ast.ru',
];

/// Whole zones that belong to the same set as [ruDirectDomains].
///
/// `xn--p1ai` is `.рф` after the IDN conversion the core performs before it
/// matches a rule, so both spellings have to be listed.
const List<String> ruDirectSuffixes = <String>[
  'ru',
  'su',
  'xn--p1ai',
];

/// True when a location name refers to Russia.
///
/// Remnawave names hosts as `🇷🇺 Москва`, `🇷🇺 Санкт-Петербург` and sometimes just
/// `Russia`, so both the flag and the common spellings are recognised.
bool isRussianLocation(String name) {
  final lower = name.toLowerCase();
  // 🇷🇺 is the regional-indicator pair for RU.
  if (name.contains('\u{1F1F7}\u{1F1FA}')) return true;
  const markers = <String>[
    'россия',
    'москва',
    'moscow',
    'санкт-петербург',
    'спб',
    'saint petersburg',
    'st. petersburg',
    'petersburg',
    'новосибирск',
    'екатеринбург',
    'казань',
    'russia',
    'russian',
    'рф',
  ];
  return markers.any(lower.contains);
}

/// Names of the generated proxy groups; the UI and the engine both reference
/// them when switching servers, so they live in one place.
class MihomoGroupNames {
  static const String auto = 'AUTO';
  static const String fallback = 'FALLBACK';
  static const String select = 'PROXY';
  static const String direct = 'DIRECT';
}

/// How automatic selection treats a location.
///
/// The panel ships Russian locations, and routing a user's traffic through them
/// is the opposite of what a gaming VPN is for, so they are excluded from the
/// automatic pool by default. They stay available for an explicit manual pick.
class AutoSelectPolicy {
  const AutoSelectPolicy({
    this.ignoreRussian = true,
    this.toleranceMs = 60,
    this.intervalSeconds = 180,
  });

  /// Keeps Russian locations out of the automatic group.
  final bool ignoreRussian;

  /// How much faster a candidate must be before the core switches to it.
  ///
  /// This is the anti-flapping control: without it two equivalent nodes trade
  /// places on every probe, and each swap re-establishes connections.
  final int toleranceMs;

  /// How often the core re-probes the pool, in seconds.
  final int intervalSeconds;
}

/// Serialises a subscription into a complete mihomo `config.yaml`.
///
/// Automatic server selection is delegated to the core itself: mihomo's
/// `url-test` group probes every node through its own proxy stack and keeps the
/// fastest one selected, which is both more accurate and far cheaper than
/// measuring latency from Dart and reloading the profile on every change.
class MihomoConfigBuilder {
  const MihomoConfigBuilder();

  String build(MihomoConfigOptions options) {
    if (options.servers.isEmpty) {
      throw StateError('Нет серверов для генерации профиля');
    }

    final buffer = StringBuffer()
      ..writeln('# ScaleGuard generated profile — do not edit by hand.')
      ..writeln('# core: mihomo (Clash.Meta)')
      ..writeln('mixed-port: ${options.mixedPort}')
      ..writeln('allow-lan: false')
      ..writeln('bind-address: 127.0.0.1')
      ..writeln('mode: rule')
      ..writeln('log-level: ${options.logLevel}')
      ..writeln('ipv6: ${options.enableIpv6}')
      // `unified-delay` measures full request time instead of TCP handshake,
      // which matches what the user perceives as "ping".
      ..writeln('unified-delay: true')
      ..writeln('tcp-concurrent: true')
      // Process rules keep the download clients — and, in game mode, the games —
      // out of the tunnel. `strict` resolves a process only for the connections
      // that reach such a rule, so everything the domain rules already matched
      // pays nothing for it.
      ..writeln('find-process-mode: strict')
      ..writeln('geodata-mode: false')
      // NOTE: `global-client-fingerprint` was removed from mihomo in 1.19.x; the
      // fingerprint is set per proxy instead (`client-fingerprint`), which the
      // subscription parser and the Xray JSON converter already emit. Passing the
      // old key makes the core log an error and ignore it.
      ..writeln('external-controller: 127.0.0.1:${options.controllerPort}')
      ..writeln('secret: "${_escape(options.secret)}"');

    if (options.cacheDir != null && options.cacheDir!.isNotEmpty) {
      buffer.writeln('profile:');
      buffer.writeln('  store-selected: true');
      buffer.writeln('  store-fake-ip: true');
    }

    _writeDns(buffer, options);
    _writeProxies(buffer, options);
    _writeProxyGroups(buffer, options);
    _writeRules(buffer, options);
    _writeTun(buffer, options);

    return buffer.toString();
  }

  void _writeDns(StringBuffer buffer, MihomoConfigOptions options) {
    // `fake-ip` is only correct in TUN mode, where the core sees the resulting
    // connection itself and can map the synthetic address back to the hostname.
    // With the Windows system proxy the client, not the core, performs the DNS
    // lookup, so a fake address would be sent straight to the proxy — which
    // cannot resolve it and the connection dies. `redir-host` resolves locally
    // and passes the real hostname on.
    final fakeIp = options.mode == VpnTunnelMode.tun;

    buffer
      ..writeln('dns:')
      ..writeln('  enable: true')
      ..writeln('  ipv6: ${options.enableIpv6}')
      ..writeln('  listen: 127.0.0.1:${options.mixedPort + 1000}')
      ..writeln('  enhanced-mode: ${fakeIp ? 'fake-ip' : 'redir-host'}');
    if (fakeIp) {
      buffer
        ..writeln('  fake-ip-range: 198.18.0.1/16')
        ..writeln('  fake-ip-filter:')
        ..writeln('    - "*.lan"')
        ..writeln('    - "*.local"')
        ..writeln('    - "+.msftconnecttest.com"')
        ..writeln('    - "+.msftncsi.com"');
    }
    buffer
      // Plain addresses are needed to reach the encrypted resolvers below
      // themselves, so these two stay unencrypted whatever the user picked.
      ..writeln('  default-nameserver:')
      ..writeln('    - 1.1.1.1')
      ..writeln('    - 77.88.8.8')
      // One resolver setup for both settings on purpose. The filtering AdGuard
      // resolver was switched on together with the ad-blocking rules, and on
      // networks where its DoH endpoint is slow or blocked every name that went
      // through it failed as well — which looked like "half of the internet is
      // gone" and was blamed on the ad blocker. Blocking is done by the REJECT
      // rules above, which do not care who resolved the name; DNS is left to
      // resolvers that answer first, with a plain one as the last resort.
      ..writeln('  nameserver:')
      ..writeln('    - https://1.1.1.1/dns-query')
      ..writeln('    - https://dns.google/dns-query')
      ..writeln('  fallback:')
      ..writeln('    - 77.88.8.8')
      ..writeln('    - 8.8.8.8')
      ..writeln('    - 1.1.1.1');
    // mihomo enables the GeoIP fallback filter by default, which forces an
    // MMDB download at startup. The client deliberately ships no geo
    // databases (routing is CIDR-based), so the filter is switched off
    // explicitly rather than left to fail on a blocked network.
    buffer
      ..writeln('  fallback-filter:')
      ..writeln('    geoip: false');
  }

  void _writeProxies(StringBuffer buffer, MihomoConfigOptions options) {
    buffer.writeln('proxies:');
    for (final server in options.servers) {
      buffer.writeln('  - ${_flowMap(server.proxy, 4)}');
    }
  }

  void _writeProxyGroups(StringBuffer buffer, MihomoConfigOptions options) {
    final names = options.servers
        .map((server) => server.proxy['name'] as String)
        .toList();
    final policy = options.autoSelectPolicy;

    // Nodes the automatic group may use. Russian locations are filtered out
    // because sending a user's traffic through them defeats the purpose of the
    // service; they remain selectable by hand.
    final automaticNames = policy.ignoreRussian
        ? names.where((name) => !isRussianLocation(name)).toList()
        : List<String>.from(names);
    // A policy that excludes everything would leave the group empty and the core
    // would refuse to start, so it falls back to the full list.
    final autoPool = automaticNames.isEmpty ? names : automaticNames;

    final quotedNames = names.map((name) => '"${_escape(name)}"').join(', ');
    final quotedAuto = autoPool.map((name) => '"${_escape(name)}"').join(', ');

    buffer
      ..writeln('proxy-groups:')
      // AUTO: the core measures the pool and keeps the fastest member selected.
      // `tolerance` is what makes this silent: a candidate must be clearly
      // faster before the core switches, so two equivalent nodes do not trade
      // places on every probe and drop connections in the process.
      ..writeln('  - name: "${MihomoGroupNames.auto}"')
      ..writeln('    type: url-test')
      ..writeln('    url: "${options.urlTestUrl}"')
      ..writeln('    interval: ${policy.intervalSeconds}')
      ..writeln('    tolerance: ${policy.toleranceMs}')
      ..writeln('    timeout: 3000')
      ..writeln('    max-failed-times: 3')
      ..writeln('    lazy: false')
      ..writeln('    proxies: [$quotedAuto]')
      // FALLBACK: ordered failover across every node, including the ones the
      // automatic pool excludes.
      ..writeln('  - name: "${MihomoGroupNames.fallback}"')
      ..writeln('    type: fallback')
      ..writeln('    url: "${options.urlTestUrl}"')
      ..writeln('    interval: ${policy.intervalSeconds}')
      ..writeln('    timeout: 3000')
      ..writeln('    lazy: false')
      ..writeln('    proxies: [$quotedNames]')
      // PROXY: what the rules and the UI point at. Every entry is emitted as its
      // own sequence item — a flow-style list cannot be mixed into a block
      // sequence, and doing so produces YAML the core rejects with
      // "did not find expected '-' indicator".
      ..writeln('  - name: "${MihomoGroupNames.select}"')
      ..writeln('    type: select')
      ..writeln('    proxies:')
      ..writeln('      - "${MihomoGroupNames.auto}"')
      ..writeln('      - "${MihomoGroupNames.fallback}"')
      ..writeln('      - "${MihomoGroupNames.direct}"');
    for (final name in names) {
      buffer.writeln('      - "${_escape(name)}"');
    }
  }

  void _writeRules(StringBuffer buffer, MihomoConfigOptions options) {
    buffer.writeln('rules:');
    // Private ranges are matched by explicit CIDR rather than `GEOIP,private`:
    // the GEOIP rule needs an MMDB database the core would have to download,
    // and a VPN client must start correctly on a machine with no internet at
    // all (for example while the user's other client is broken).
    buffer
      ..writeln('  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR6,fc00::/7,DIRECT,no-resolve')
      ..writeln('  - IP-CIDR6,fe80::/10,DIRECT,no-resolve')
      ..writeln('  - DOMAIN-SUFFIX,local,DIRECT')
      ..writeln('  - DOMAIN-SUFFIX,lan,DIRECT');

    // The user's own list forces those domains through the location. It comes
    // first of everything that is a choice rather than a necessity: naming a
    // domain here is the most explicit instruction the application ever
    // receives, so nothing below may override it — not the Russian services that
    // normally stay direct, not bulk downloads, not the ad filter's neighbours.
    // A domain reaches the core as a hostname in both modes — the core sees it
    // in a `CONNECT` under the system proxy and takes it out of the tunnel's own
    // DNS in TUN mode — which is what makes the list work in either mode, and
    // why it matters most with the system proxy on: that is the mode where a
    // domain would otherwise keep the machine's own route.
    for (final domain in options.bypassDomains) {
      if (isIpv4(domain)) {
        buffer.writeln('  - IP-CIDR,$domain/32,PROXY,no-resolve');
      } else {
        buffer.writeln('  - DOMAIN-SUFFIX,$domain,PROXY');
      }
    }

    // Russian services stay on the user's own connection.
    //
    // This is not only about speed: a bank or a government portal that sees a
    // foreign exit address reacts the way it does for any anonymous proxy —
    // with an extra confirmation step, or with a block. Keeping the whole `.ru`
    // zone on the real connection is what makes those applications behave as if
    // there were no VPN at all, which is exactly what the user is after.
    if (options.ruDirect) {
      for (final domain in ruDirectDomains) {
        buffer.writeln('  - DOMAIN-SUFFIX,$domain,DIRECT');
      }
      for (final suffix in ruDirectSuffixes) {
        buffer.writeln('  - DOMAIN-SUFFIX,$suffix,DIRECT');
      }
      // Names ending in `.ru` are the easy half. A bank's API, a courier's
      // tracking endpoint and half the government portals live on `.com` hosts
      // behind a Russian network, and those see a foreign exit exactly like any
      // other proxy. Routing by address as well is what makes the promise true
      // for them too, and it is the only rule that also covers traffic that
      // arrives as a bare IP with no hostname attached.
      for (final cidr in ruCidrs()) {
        buffer.writeln('  - IP-CIDR,$cidr,DIRECT');
      }
    }

    // Bulk downloads never enter the tunnel.
    //
    // A torrent swarm or a game-store download saturates the link for hours at a
    // time, and exit bandwidth is the scarce resource in a subscription. Leaving
    // those flows on the user's own connection keeps browsing, streaming and
    // gaming fast, and keeps the metered traffic on the side that is not
    // measured.
    for (final domain in bulkDownloadDomains) {
      buffer.writeln('  - DOMAIN-SUFFIX,$domain,DIRECT');
    }
    if (options.gameMode) {
      // Games and launchers reach the provider directly.
      for (final domain in gameDirectDomains) {
        buffer.writeln('  - DOMAIN-SUFFIX,$domain,DIRECT');
      }
    }
    // Process rules come last on purpose. `find-process-mode: strict` resolves a
    // process name only for the connections that actually reach one of these
    // rules, so everything matched above — the private ranges, local names and
    // the download domains — never pays for the lookup. They are also the only
    // rules that can catch traffic which arrives as a bare IP address: a game's
    // own sessions and a torrent peer, neither of which carries a domain.
    for (final name in _directProcessNames(options.gameMode)) {
      buffer.writeln('  - PROCESS-NAME,$name,DIRECT');
    }
    // The tunnel is always global: everything not listed above goes through
    // the proxy, so the exit IP and country always change.
    buffer.writeln('  - MATCH,${MihomoGroupNames.select}');
  }

  /// Executables that keep their traffic off the tunnel.
  ///
  /// The download clients are always present; the game clients only in game
  /// mode, where keeping a game on the direct route is the whole point.
  List<String> _directProcessNames(bool gameMode) => gameMode
      ? <String>[...bulkDownloadProcessNames, ...gameProcessNames]
      : bulkDownloadProcessNames;

  void _writeTun(StringBuffer buffer, MihomoConfigOptions options) {
    if (options.mode != VpnTunnelMode.tun) return;
    buffer
      ..writeln('tun:')
      ..writeln('  enable: true')
      ..writeln('  device: "${options.tunDeviceName}"')
      // `mixed` uses the system stack for TCP and gVisor for UDP: it is the
      // best balance of throughput and compatibility on Windows.
      ..writeln('  stack: mixed');
    // The core's own defaults are 198.18.0.1/30 and fdfe:dcba:9876::1/126 — the
    // same pair every Clash-family client ships with. Windows rejects an address
    // another adapter already holds, so a machine running one of them cannot
    // start this tunnel until it asks for addresses of its own.
    //
    // Both keys are sequences in the core's schema. A bare scalar is read as a
    // string and the whole profile is rejected ("cannot unmarshal !!str … into
    // []netip.Prefix"), which looks like a controller that never answered.
    final addresses = options.tunAddresses;
    if (addresses != null) {
      if (addresses.v4.isNotEmpty) {
        buffer.writeln('  inet4-address: [${addresses.v4}]');
      }
      if (addresses.v6.isNotEmpty) {
        buffer.writeln('  inet6-address: [${addresses.v6}]');
      }
    }
    buffer
      ..writeln('  auto-route: true')
      ..writeln('  auto-detect-interface: true')
      ..writeln('  strict-route: true')
      ..writeln('  mtu: 9000')
      ..writeln('  dns-hijack:')
      ..writeln('    - any:53');
  }

  /// Emits a YAML flow mapping. Flow style keeps every proxy on a single line,
  /// which makes the generated profile diff-friendly and cheap to rewrite.
  String _flowMap(Map<String, dynamic> map, int indent) {
    final buffer = StringBuffer('{');
    var first = true;
    map.forEach((key, value) {
      if (!first) buffer.write(', ');
      first = false;
      buffer
        ..write(_flowKey(key))
        ..write(': ')
        ..write(_flowValue(value, indent));
    });
    buffer.write('}');
    return buffer.toString();
  }

  String _flowKey(String key) {
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$').hasMatch(key)) return key;
    return '"${_escape(key)}"';
  }

  String _flowValue(dynamic value, int indent) {
    if (value == null) return 'null';
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    if (value is List) {
      return '[${value.map((item) => _flowValue(item, indent)).join(', ')}]';
    }
    if (value is Map) {
      final map = value.map((key, item) => MapEntry(key.toString(), item));
      return _flowMap(map, indent);
    }
    return '"${_escape(value.toString())}"';
  }

  String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
}

/// The subset of a subscription's metadata a client can show without asking the
/// website API again. Remnawave advertises these through response headers.
class SubscriptionMetadata {
  const SubscriptionMetadata({
    this.title,
    this.webPageUrl,
    this.supportUrl,
    this.updateIntervalHours,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireAt,
  });

  final String? title;
  final String? webPageUrl;
  final String? supportUrl;
  final int? updateIntervalHours;
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final DateTime? expireAt;

  /// Parses the `subscription-userinfo` header, e.g.
  /// `upload=0; download=1610612736; total=0; expire=1767225600`.
  static SubscriptionMetadata fromHeaders(Map<String, String> headers) {
    final lower = <String, String>{};
    headers.forEach((key, value) => lower[key.toLowerCase()] = value);

    int? upload;
    int? download;
    int? total;
    DateTime? expire;

    final userInfo = lower['subscription-userinfo'];
    if (userInfo != null && userInfo.isNotEmpty) {
      for (final part in userInfo.split(';')) {
        final trimmed = part.trim();
        final equals = trimmed.indexOf('=');
        if (equals < 0) continue;
        final key = trimmed.substring(0, equals).trim().toLowerCase();
        final raw = trimmed.substring(equals + 1).trim();
        switch (key) {
          case 'upload':
            upload = int.tryParse(raw);
          case 'download':
            download = int.tryParse(raw);
          case 'total':
            total = int.tryParse(raw);
          case 'expire':
            final seconds = int.tryParse(raw);
            if (seconds != null && seconds > 0) {
              expire = DateTime.fromMillisecondsSinceEpoch(
                seconds * 1000,
                isUtc: true,
              );
            }
        }
      }
    }

    return SubscriptionMetadata(
      title: lower['profile-title'],
      webPageUrl: lower['profile-web-page-url'],
      supportUrl: lower['support-url'],
      updateIntervalHours: int.tryParse(lower['profile-update-interval'] ?? ''),
      uploadBytes: upload,
      downloadBytes: download,
      totalBytes: total,
      expireAt: expire,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'webPageUrl': webPageUrl,
        'supportUrl': supportUrl,
        'updateIntervalHours': updateIntervalHours,
        'uploadBytes': uploadBytes,
        'downloadBytes': downloadBytes,
        'totalBytes': totalBytes,
        'expireAt': expireAt?.toIso8601String(),
      };

  static SubscriptionMetadata fromJson(Map<String, dynamic> json) {
    final expireRaw = json['expireAt']?.toString();
    return SubscriptionMetadata(
      title: json['title']?.toString(),
      webPageUrl: json['webPageUrl']?.toString(),
      supportUrl: json['supportUrl']?.toString(),
      updateIntervalHours: (json['updateIntervalHours'] as num?)?.toInt(),
      uploadBytes: (json['uploadBytes'] as num?)?.toInt(),
      downloadBytes: (json['downloadBytes'] as num?)?.toInt(),
      totalBytes: (json['totalBytes'] as num?)?.toInt(),
      expireAt: expireRaw == null ? null : DateTime.tryParse(expireRaw),
    );
  }

  String encode() => jsonEncode(toJson());
}

import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime configuration.
///
/// Values come from the bundled `.env` asset, and every one of them can be
/// overridden at build time with `--dart-define`, which is what makes it
/// possible to point the same binary at a staging API (or at the local mock used
/// by the end-to-end test) without editing the asset:
///
/// ```
/// flutter build apk --dart-define=API_URL=http://10.0.2.2:8787
/// ```
class AppConfig {
  /// API base URL, without a trailing slash.
  static String get apiUrl {
    final override = const String.fromEnvironment('API_URL');
    final raw = override.isNotEmpty
        ? override
        : dotenv.env['API_URL']?.trim() ?? '';
    final value = raw.isEmpty ? 'https://apiscaleguard.inzeworld.com' : raw;
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  /// Deep link the server redirects to after Yandex OAuth.
  static String get mobileReturnOrigin {
    final override = const String.fromEnvironment('MOBILE_RETURN_ORIGIN');
    if (override.isNotEmpty) return override;
    return dotenv.env['MOBILE_RETURN_ORIGIN']?.trim() ?? 'scaleguard://oauth';
  }

  static const appName = 'ScaleGuard';
  static const telegramBotName = 'ScaleGuard_bot';

  /// GitHub repository the self-updater reads releases from.
  ///
  /// The release tagged *Latest* is the version offered to every install older
  /// than it. Override at build time with `--dart-define=UPDATE_REPO=owner/name`
  /// for a fork or a staging channel.
  static String get updateRepo {
    final override = const String.fromEnvironment('UPDATE_REPO');
    return override.isEmpty ? 'INZEWORLD/ScaleGuard' : override;
  }

  /// Human-readable release page, used by the settings screen.
  static String get releasesUrl => 'https://github.com/$updateRepo/releases';

  /// Where the support team answers, as opposed to the bot that only hands out
  /// subscription links.
  static const supportUrl = 'https://t.me/INZEWORLD_SUPPORT';

  /// The public channel: release notes, new locations and promotions.
  static const telegramChannelUrl = 'https://t.me/inzeworld_official';

  /// The community server.
  static const discordUrl = 'https://discord.gg/xTmekE7Urz';

  static const termsUrl = 'https://scaleguard.gitbook.io/scaleguard-info';

  static String get privacyUrl => '$websiteUrl/privacy.html';

  /// Public website URL, without a trailing slash.
  static String get websiteUrl {
    final override = const String.fromEnvironment('WEBSITE_URL');
    final raw = override.isNotEmpty
        ? override
        : dotenv.env['WEBSITE_URL']?.trim() ?? '';
    final value = raw.isEmpty ? 'https://scaleguard.inzeworld.com' : raw;
    return value.replaceAll(RegExp(r'/+$'), '');
  }
}

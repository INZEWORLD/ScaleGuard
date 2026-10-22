int? jsonInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

num jsonNum(dynamic value, [num fallback = 0]) {
  if (value == null) return fallback;
  if (value is num) return value;
  return num.tryParse(value.toString()) ?? fallback;
}

String jsonString(dynamic value, [String fallback = '']) {
  if (value == null) return fallback;
  return value.toString();
}

class PublicUser {
  PublicUser({
    required this.id,
    required this.email,
    required this.name,
    required this.balance,
    required this.role,
    required this.hasTg,
    required this.hasYandex,
    this.telegramId,
    this.subscriptionPlanId,
    this.autoRenewEnabled,
  });

  final int id;
  final String email;
  final String? name;
  final num balance;
  final String role;
  final bool hasTg;
  final bool hasYandex;
  final int? telegramId;
  final int? subscriptionPlanId;
  final bool? autoRenewEnabled;

  factory PublicUser.fromJson(Map<String, dynamic> json) {
    return PublicUser(
      id: jsonInt(json['id']) ?? 0,
      email: jsonString(json['email']),
      name: json['name']?.toString(),
      balance: jsonNum(json['balance']),
      role: jsonString(json['role'], 'user'),
      hasTg: json['has_tg'] == true,
      hasYandex: json['has_yandex'] == true,
      telegramId: jsonInt(json['telegramId'] ?? json['telegram_id'] ?? json['tg_id']),
      subscriptionPlanId: jsonInt(json['subscriptionPlanId'] ?? json['subscription_plan_id']),
      autoRenewEnabled: json['autoRenewEnabled'] as bool?,
    );
  }
}

class TunnelInfo {
  TunnelInfo({
    required this.status,
    required this.subscriptionUrl,
    this.expireAt,
    this.trafficLimitBytes,
    this.usedTrafficBytes,
    this.username,
    this.uuid,
  });

  final String status;
  final String subscriptionUrl;
  final String? expireAt;
  final num? trafficLimitBytes;
  final num? usedTrafficBytes;
  final String? username;
  final String? uuid;

  bool get hasActiveSubscription {
    if (subscriptionUrl.trim().isEmpty) return false;
    final s = status.toUpperCase();
    if (s == 'ACTIVE' || s == 'LIMITED') return true;
    if (expireAt != null && expireAt!.isNotEmpty) {
      final exp = DateTime.tryParse(expireAt!);
      if (exp != null && exp.isAfter(DateTime.now())) return true;
    }
    return false;
  }

  factory TunnelInfo.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return TunnelInfo(status: '', subscriptionUrl: '');
    }
    final trafficRaw = json['userTraffic'];
    final traffic = trafficRaw is Map ? Map<String, dynamic>.from(trafficRaw) : null;
    return TunnelInfo(
      status: jsonString(json['status']),
      subscriptionUrl: jsonString(json['subscriptionUrl'] ?? json['subscription_url']),
      expireAt: json['expireAt']?.toString() ?? json['expire_at']?.toString(),
      trafficLimitBytes: jsonNum(json['trafficLimitBytes'] ?? json['traffic_limit_bytes'], 0),
      usedTrafficBytes: jsonNum(traffic?['usedTrafficBytes'] ?? traffic?['used_traffic_bytes'], 0),
      username: json['username']?.toString(),
      uuid: json['uuid']?.toString(),
    );
  }
}

class TrialInfo {
  TrialInfo({
    required this.enabled,
    required this.available,
    required this.activated,
    this.durationDays,
  });

  final bool enabled;
  final bool available;
  final bool activated;
  final int? durationDays;

  factory TrialInfo.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return TrialInfo(enabled: false, available: false, activated: false);
    }
    // The panel names the flag `eligible`; `available` is the name this client
    // was written against. Reading both is what keeps the 2-day trial from
    // disappearing whenever one side of that pair is deployed on its own.
    final eligible = json['available'] == true || json['eligible'] == true;
    return TrialInfo(
      enabled: json['enabled'] == true,
      available: eligible,
      activated: json['activated'] == true || json['used'] == true,
      durationDays: jsonInt(json['durationDays'] ?? json['duration_days']),
    );
  }
}

class AuthConfig {
  AuthConfig({
    required this.telegramEnabled,
    required this.yandexEnabled,
    required this.hcaptchaEnabled,
    this.telegramBotName,
    this.hcaptchaSiteKey,
    this.qrLoginEnabled = false,
  });

  final bool telegramEnabled;
  final bool yandexEnabled;
  final bool hcaptchaEnabled;
  final String? telegramBotName;
  final String? hcaptchaSiteKey;

  /// Whether this panel can sign a device in from a QR code.
  ///
  /// A panel that predates the feature simply does not say so, and the buttons
  /// stay hidden rather than failing when they are pressed.
  final bool qrLoginEnabled;

  factory AuthConfig.fromJson(Map<String, dynamic> json) {
    return AuthConfig(
      telegramEnabled: json['telegramEnabled'] == true,
      yandexEnabled: json['yandexEnabled'] == true,
      hcaptchaEnabled: json['hcaptchaEnabled'] == true,
      telegramBotName: json['telegramBotName'] as String?,
      hcaptchaSiteKey: json['hcaptchaSiteKey'] as String?,
      qrLoginEnabled: json['qrLoginEnabled'] == true,
    );
  }
}

/// One short-lived QR sign-in session.
class QrLoginSession {
  QrLoginSession({
    required this.sessionId,
    required this.link,
    required this.expiresAt,
  });

  /// Identifier the server knows this session by.
  final String sessionId;

  /// What the code on screen encodes.
  final String link;

  /// When the server stops accepting it.
  final DateTime expiresAt;

  factory QrLoginSession.fromJson(Map<String, dynamic> json) {
    return QrLoginSession(
      sessionId: json['sessionId'] as String? ?? '',
      link: json['link'] as String? ?? '',
      expiresAt:
          DateTime.tryParse(json['expiresAt'] as String? ?? '') ??
          DateTime.now().add(const Duration(minutes: 3)),
    );
  }
}

class ProfileSnapshot {
  ProfileSnapshot({
    required this.user,
    required this.tunnel,
    required this.trial,
    this.remnawaveSyncPending = false,
  });

  final PublicUser user;
  final TunnelInfo tunnel;
  final TrialInfo trial;
  final bool remnawaveSyncPending;

  factory ProfileSnapshot.fromJson(Map<String, dynamic> json) {
    return ProfileSnapshot(
      user: PublicUser.fromJson(json['user'] as Map<String, dynamic>),
      tunnel: TunnelInfo.fromJson(json['tunnel'] as Map<String, dynamic>?),
      trial: TrialInfo.fromJson(json['trial'] as Map<String, dynamic>?),
      remnawaveSyncPending: json['remnawaveSyncPending'] == true,
    );
  }
}

/// One selectable server, normalised for the mihomo core.
///
/// [proxy] is the mihomo `proxies:` entry (the single currency shared by the
/// Windows sidecar and the Android native core); [configJson] keeps the
/// original JSON form for diagnostics and for features that need the raw
/// subscription data.
class VpnServerProfile {
  VpnServerProfile({
    required this.remark,
    required this.configJson,
    this.protocol = '',
    this.server = '',
    this.port = 0,
    this.countryCode,
    Map<String, dynamic>? proxy,
  }) : proxy = proxy ?? const <String, dynamic>{};

  final String remark;
  final String configJson;

  /// Lower-case mihomo proxy type: vless, vmess, trojan, ss, hysteria2, …
  final String protocol;

  /// Endpoint address and port, shown in the server list.
  final String server;
  final int port;

  /// ISO-3166 alpha-2 code parsed from the remark when the panel provides one.
  final String? countryCode;

  /// The mihomo proxy definition handed to the core.
  final Map<String, dynamic> proxy;

  String get endpoint => server.isEmpty ? remark : '$server:$port';
}

class VpnPlan {
  VpnPlan({
    required this.id,
    required this.title,
    required this.description,
    required this.periodLabel,
    required this.chargeRub,
    required this.listPriceRub,
    this.isPopular = false,
    this.promoDiscountPercent,
  });

  final int id;
  final String title;
  final String description;
  final String periodLabel;
  final int chargeRub;
  final int listPriceRub;
  final bool isPopular;
  final int? promoDiscountPercent;

  factory VpnPlan.fromJson(Map<String, dynamic> json) {
    final charge = json['balance_charge_rub'] ?? json['price'];
    final list = json['list_price_rub'] ?? json['price'];
    return VpnPlan(
      id: jsonInt(json['id']) ?? 0,
      title: jsonString(json['title'], 'Тариф'),
      description: jsonString(json['description']),
      periodLabel: jsonString(json['period_label'] ?? json['periodLabel']),
      chargeRub: jsonNum(charge).floor(),
      listPriceRub: jsonNum(list).floor(),
      isPopular: json['is_popular'] == 1 || json['is_popular'] == true,
      promoDiscountPercent: jsonInt(json['promo_discount_percent']),
    );
  }
}

class PaymentProviders {
  PaymentProviders({required this.yookassa, required this.platega});

  final bool yookassa;
  final bool platega;

  factory PaymentProviders.fromJson(Map<String, dynamic> json) {
    return PaymentProviders(
      yookassa: json['yookassa'] == true,
      platega: json['platega'] == true,
    );
  }

  /// The provider the client pays through.
  ///
  /// YooKassa is preferred whenever it is offered: it is the one the website
  /// leads with, and an account that pays on both surfaces should not have two
  /// different stories about where the money went.
  String get defaultProvider => yookassa ? 'yookassa' : 'platega';
}

/// One device the panel has bound to the subscription.
class HwidDevice {
  HwidDevice({
    required this.hwid,
    this.deviceModel,
    this.platform,
    this.osVersion,
    this.userAgent,
    this.createdAt,
  });

  /// Hardware identifier the panel keys the binding on.
  final String hwid;
  final String? deviceModel;
  final String? platform;
  final String? osVersion;
  final String? userAgent;
  final String? createdAt;

  /// What the list shows above the identifier.
  String get title {
    final model = deviceModel?.trim() ?? '';
    if (model.isNotEmpty) return model;
    final platformName = platform?.trim() ?? '';
    if (platformName.isNotEmpty) return platformName;
    return 'Устройство';
  }

  /// Platform and version, when the panel knows them.
  String get subtitle {
    final parts = <String>[
      if ((platform ?? '').trim().isNotEmpty) platform!.trim(),
      if ((osVersion ?? '').trim().isNotEmpty) osVersion!.trim(),
    ];
    return parts.join(' · ');
  }

  /// The first and last block of the identifier, which is all a user needs to
  /// tell two of their own machines apart.
  String get shortHwid {
    if (hwid.length <= 14) return hwid;
    return '${hwid.substring(0, 6)}…${hwid.substring(hwid.length - 6)}';
  }

  factory HwidDevice.fromJson(Map<String, dynamic> json) {
    return HwidDevice(
      hwid: jsonString(json['hwid'] ?? json['id']),
      deviceModel: json['deviceModel']?.toString() ?? json['device_model']?.toString(),
      platform: json['platform']?.toString(),
      osVersion: json['osVersion']?.toString() ?? json['os_version']?.toString(),
      userAgent: json['userAgent']?.toString() ?? json['user_agent']?.toString(),
      createdAt: json['createdAt']?.toString() ?? json['created_at']?.toString(),
    );
  }
}

/// The device list together with the limit the subscription allows.
class HwidDevices {
  HwidDevices({
    required this.total,
    required this.limit,
    required this.devices,
    this.panelUsername,
  });

  final int total;
  final int limit;
  final List<HwidDevice> devices;
  final String? panelUsername;

  bool get hasLimit => limit > 0;
  bool get isFull => hasLimit && total >= limit;

  factory HwidDevices.fromJson(Map<String, dynamic> json) {
    final raw = json['devices'];
    return HwidDevices(
      total: jsonInt(json['total']) ?? 0,
      limit: jsonInt(json['limit']) ?? 0,
      panelUsername: json['panelUsername']?.toString(),
      devices: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => HwidDevice.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const <HwidDevice>[],
    );
  }
}

class TopUpSession {
  TopUpSession({
    required this.paymentId,
    required this.paymentUrl,
    required this.provider,
    this.planId,
  });

  final String paymentId;
  final String paymentUrl;
  final String provider;
  final int? planId;
}

class TopUpConfirmResult {
  TopUpConfirmResult({
    required this.success,
    this.planId,
    this.autoPurchase,
    this.user,
  });

  final bool success;
  final int? planId;
  final bool? autoPurchase;
  final PublicUser? user;

  factory TopUpConfirmResult.fromJson(Map<String, dynamic> json) {
    return TopUpConfirmResult(
      success: json['success'] == true,
      planId: (json['planId'] as num?)?.toInt(),
      autoPurchase: json['autoPurchase'] as bool?,
      user: json['user'] != null
          ? PublicUser.fromJson(json['user'] as Map<String, dynamic>)
          : null,
    );
  }
}

class PurchaseResult {
  PurchaseResult({
    required this.success,
    this.message,
    this.activationPending,
    this.user,
    this.insufficientBalance,
  });

  final bool success;
  final String? message;
  final bool? activationPending;
  final PublicUser? user;
  final InsufficientBalanceDetail? insufficientBalance;

  factory PurchaseResult.fromJson(Map<String, dynamic> json, {required int statusCode}) {
    if (statusCode == 409 && json['code'] == 'INSUFFICIENT_BALANCE') {
      return PurchaseResult(
        success: false,
        insufficientBalance: InsufficientBalanceDetail.fromJson(json),
      );
    }
    return PurchaseResult(
      success: json['success'] == true,
      message: json['message'] as String?,
      activationPending: json['activationPending'] as bool?,
      user: json['user'] != null
          ? PublicUser.fromJson(json['user'] as Map<String, dynamic>)
          : null,
    );
  }
}

class InsufficientBalanceDetail {
  InsufficientBalanceDetail({
    required this.planId,
    required this.planTitle,
    required this.planPrice,
    required this.currentBalance,
    required this.requiredTopUp,
  });

  final int planId;
  final String planTitle;
  final num planPrice;
  final num currentBalance;
  final num requiredTopUp;

  factory InsufficientBalanceDetail.fromJson(Map<String, dynamic> json) {
    final plan = json['plan'] as Map<String, dynamic>?;
    return InsufficientBalanceDetail(
      planId: (plan?['id'] as num?)?.toInt() ?? (json['planId'] as num?)?.toInt() ?? 0,
      planTitle: (plan?['title'] as String?) ?? 'Тариф',
      planPrice: json['planPrice'] as num? ?? plan?['price'] as num? ?? 0,
      currentBalance: json['currentBalance'] as num? ?? 0,
      requiredTopUp: json['requiredTopUp'] as num? ?? 0,
    );
  }
}

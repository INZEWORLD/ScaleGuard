import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';

/// The devices the subscription is bound to.
///
/// The panel enforces a device limit on the subscription itself, and the client
/// used to hit it as nothing more than a failed connection. This page is the
/// same list the website shows, so a slot can be freed from inside the
/// application instead of from a browser session.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadDevices();
    });
  }

  Future<void> _confirmRemove(AppState state, HwidDevice device) async {
    final ok = await _confirm(
      context,
      title: 'Отключить устройство?',
      text: '«${device.title}» потеряет доступ к подписке. Вернуть его можно '
          'только подключением заново.',
      action: 'Отключить',
    );
    if (ok) await state.removeDevice(device.hwid);
  }

  Future<void> _confirmRemoveAll(AppState state) async {
    final ok = await _confirm(
      context,
      title: 'Отключить все устройства?',
      text: 'Доступ потеряют все машины, включая эту. Их можно подключить заново.',
      action: 'Отключить все',
    );
    if (ok) await state.removeAllDevices();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);
    final data = state.devices;
    final devices = data?.devices ?? const <HwidDevice>[];
    final tunnel = state.tunnel;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (!widget.embedded) const AuroraBackdrop(),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (!widget.embedded)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                  child: Row(
                    children: [
                      Text(
                        'Устройства',
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Обновить',
                        onPressed: state.busy ? null : () => state.loadDevices(),
                        icon: Icon(Icons.refresh_rounded, color: c.muted),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 108),
                    children: [
                      if (tunnel != null && tunnel.hasActiveSubscription)
                        _SummaryCard(tunnel: tunnel, devices: data),
                      const SizedBox(height: 14),
                      if (state.devicesLoading && data == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 36),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else ...[
                        if (data != null && devices.isNotEmpty) ...[
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  data.hasLimit
                                      ? 'Занято ${data.total} из ${data.limit}'
                                      : 'Подключено: ${data.total}',
                                  style: TextStyle(
                                    color: c.ink,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: state.busy
                                    ? null
                                    : () => _confirmRemoveAll(state),
                                child: const Text('Отключить все'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          for (final device in devices)
                            _DeviceCard(
                              device: device,
                              busy: state.busy,
                              onRemove: () => _confirmRemove(state, device),
                            ),
                        ] else
                          _EmptyCard(
                            text: state.devicesError ??
                                'К подписке пока не привязано ни одного устройства. '
                                    'Оно появится здесь, как только вы подключитесь '
                                    'с новой машины.',
                          ),
                      ],
                      if (state.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          state.error!,
                          style: const TextStyle(color: SgColors.red, height: 1.35),
                        ),
                      ],
                      if (state.info != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          state.info!,
                          style: const TextStyle(color: SgColors.green, height: 1.35),
                        ),
                      ],
                      const SizedBox(height: 18),
                      _InviteCard(
                        onOpen: () => launchUrl(
                          Uri.parse('${AppConfig.websiteUrl}/?route=referrals'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the subscription allows and how much of it is used.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.tunnel, this.devices});

  final TunnelInfo tunnel;
  final HwidDevices? devices;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final limit = (tunnel.trafficLimitBytes ?? 0).toDouble();
    final used = (tunnel.usedTrafficBytes ?? 0).toDouble();
    final rows = <String>[
      if ((tunnel.expireAt ?? '').trim().isNotEmpty)
        'Действует до ${_date(tunnel.expireAt!)}',
      if (limit > 0) 'Трафик: ${_traffic(used)} из ${_traffic(limit)}',
      if (devices != null && devices!.hasLimit)
        'Устройства: ${devices!.total} из ${devices!.limit}',
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            SgColors.blue.withValues(alpha: 0.14),
            SgColors.violet.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: c.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: SgColors.blue.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.devices_rounded, color: SgColors.blue, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ваша подписка',
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row,
                      style: TextStyle(color: c.muted, fontSize: 13, height: 1.35),
                    ),
                  ),
                if (devices != null && devices!.isFull) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Лимит устройств заполнен. Отключите то, которым больше не '
                    'пользуетесь, чтобы подключить новое.',
                    style: TextStyle(
                      color: SgColors.violet,
                      fontSize: 12.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.busy,
    required this.onRemove,
  });

  final HwidDevice device;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final subtitle = device.subtitle;
    final added = device.createdAt == null ? null : _date(device.createdAt!);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.pill,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(_iconFor(device.platform), color: c.muted, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: c.muted, fontSize: 12.5),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'ID ${device.shortHwid}${added == null ? '' : ' · добавлено $added'}',
                  style: TextStyle(color: c.faint, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: busy ? null : onRemove,
            child: const Text('Отключить'),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(String? platform) {
    final value = (platform ?? '').toLowerCase();
    if (value.contains('android')) return Icons.smartphone_rounded;
    if (value.contains('ios') || value.contains('iphone')) {
      return Icons.phone_iphone_rounded;
    }
    if (value.contains('mac') || value.contains('darwin')) {
      return Icons.laptop_mac_rounded;
    }
    if (value.contains('win')) return Icons.desktop_windows_rounded;
    if (value.contains('linux')) return Icons.terminal_rounded;
    return Icons.devices_other_rounded;
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: c.faint, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: c.muted, height: 1.45, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: c.line),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: SgColors.violet.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.people_alt_rounded,
                color: SgColors.violet,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Пригласить друга',
                    style: TextStyle(
                      color: c.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Реферальная программа: награда за каждого, кто подключится',
                    style: TextStyle(color: c.muted, fontSize: 12.5, height: 1.35),
                  ),
                ],
              ),
            ),
            Icon(Icons.open_in_new_rounded, color: c.faint, size: 18),
          ],
        ),
      ),
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String text,
  required String action,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return answer == true;
}

String _traffic(double bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(bytes / gb >= 10 ? 0 : 1)} ГБ';
  }
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} МБ';
  return '${(bytes / 1024).toStringAsFixed(0)} КБ';
}

String _date(String raw) {
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  final local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year}';
}

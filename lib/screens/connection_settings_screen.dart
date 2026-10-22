import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/bypass_domains.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';

/// Connection settings.
///
/// Two decisions live here: how traffic reaches the exit (system proxy or global
/// TUN) and whether games are kept on the direct route. TUN is the default
/// because it is the only mode that covers every application; the system proxy
/// is the opt-in for machines where elevation is not wanted, so the two are
/// presented as one switch rather than two radio buttons.
class ConnectionSettingsScreen extends StatelessWidget {
  const ConnectionSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);
    final isWindows = Platform.isWindows;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackdrop(),
          SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                  ),
                ),
                Text(
                  'Настройка подключения',
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Выберите режим и при необходимости добавьте сайты.',
                  style: TextStyle(
                    color: c.faint,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                _ModePanel(
                  preset: state.tunnelPreset,
                  enabled: !state.busy,
                  onChanged: state.setTunnelPreset,
                  isWindows: isWindows,
                ),
                // The administrator switch and the restart that applies it live
                // in the application settings: a mode change is the only reason
                // a restart was ever needed here, and it is requested there.
                const SizedBox(height: 14),
                _GamePanel(
                  value: state.gameModeEnabled,
                  onChanged: state.setGameMode,
                ),
                const SizedBox(height: 14),
                _DomainPanel(
                  value: state.bypassDomains,
                  onSaved: state.setBypassDomains,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Card shell shared by every panel on this screen.
class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.accent});

  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final tint = accent ?? SgColors.violet;
    return Container(
      decoration: BoxDecoration(
        color: c.sheet,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: c.line),
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: 0.10),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              gradient: LinearGradient(
                colors: [
                  tint.withValues(alpha: 0),
                  tint.withValues(alpha: 0.85),
                  SgColors.teal.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: 21),
    );
  }
}

/// Icon + two lines of text + a switch.
class _ToggleHead extends StatelessWidget {
  const _ToggleHead({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Row(
      children: [
        _IconBox(icon: icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: c.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(color: c.faint, fontSize: 12, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              c.line.withValues(alpha: 0),
              c.line,
              c.line.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModePanel extends StatelessWidget {
  const _ModePanel({
    required this.preset,
    required this.enabled,
    required this.onChanged,
    required this.isWindows,
  });

  final TunnelPreset preset;
  final bool enabled;
  final ValueChanged<TunnelPreset> onChanged;
  final bool isWindows;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return _Panel(
      accent: SgColors.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Режим подключения',
            style: TextStyle(
              color: c.ink,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          _ModeTile(
            icon: Icons.alt_route_rounded,
            title: 'По правилам',
            subtitle:
                'Российские сайты — напрямую, остальные и ваши домены — через '
                'локацию.',
            badge: 'Рекомендуется',
            selected: preset == TunnelPreset.rules,
            onTap: enabled ? () => onChanged(TunnelPreset.rules) : null,
          ),
          const _Divider(),
          _ModeTile(
            icon: Icons.public_rounded,
            title: 'Весь трафик',
            subtitle: 'Всё через локацию. Банки и госуслуги могут не работать.',
            selected: preset == TunnelPreset.fullTraffic,
            onTap: enabled ? () => onChanged(TunnelPreset.fullTraffic) : null,
          ),
          const _Divider(),
          _ModeTile(
            icon: Icons.swap_horiz_rounded,
            title: 'Системный прокси',
            subtitle: isWindows
                ? 'Без прав администратора. Только браузер и программы с '
                    'системным прокси.'
                : 'Приложения используют локальный прокси. Туннель остаётся '
                    'включённым.',
            selected: preset == TunnelPreset.systemProxy,
            onTap: enabled ? () => onChanged(TunnelPreset.systemProxy) : null,
          ),
          if (preset == TunnelPreset.systemProxy) ...[
            const SizedBox(height: 10),
            _Inline(
              icon: Icons.info_outline_rounded,
              color: SgColors.violet,
              text: isWindows
                  ? 'Программы без системного прокси пойдут напрямую.'
                  : 'Трафик, который не идёт через прокси, остаётся в туннеле.',
            ),
          ],
        ],
      ),
    );
  }
}

/// One row of the mode picker: icon, title, one line of explanation, a mark.
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final accent = selected ? SgColors.teal : c.faint;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? SgColors.teal.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? SgColors.teal.withValues(alpha: 0.35)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            _IconBox(icon: icon, color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: c.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: SgColors.teal.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            badge!,
                            style: const TextStyle(
                              color: SgColors.teal,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(color: c.faint, fontSize: 12, height: 1.35),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.circle_outlined,
              color: selected
                  ? SgColors.teal
                  : c.faint.withValues(alpha: 0.45),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}

class _GamePanel extends StatelessWidget {
  const _GamePanel({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return _Panel(
      accent: SgColors.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ToggleHead(
            icon: Icons.sports_esports_rounded,
            color: SgColors.teal,
            title: 'Игровой режим',
            subtitle: 'Игры и лаунчеры идут напрямую, без локации',
            value: value,
            onChanged: onChanged,
          ),
          const SizedBox(height: 12),
          _Inline(
            icon: value ? Icons.bolt_rounded : Icons.timer_outlined,
            color: value ? SgColors.teal : c.faint,
            text: value
                ? 'Включено: в играх меньше пинг'
                : 'Выключено: игры тоже идут через локацию',
          ),
        ],
      ),
    );
  }
}

/// Russian services stay on the user's own connection.
/// The user's own list of domains that must go through the location.
class _DomainPanel extends StatefulWidget {
  const _DomainPanel({required this.value, required this.onSaved});

  /// The stored list exactly as it was typed.
  final String value;

  /// Persists and applies the field contents.
  final Future<void> Function(String raw) onSaved;

  @override
  State<_DomainPanel> createState() => _DomainPanelState();
}

class _DomainPanelState extends State<_DomainPanel> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant _DomainPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The store stays the source of truth: after a save the field shows what was
    // actually kept, because an over-long paste is trimmed on the way in.
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSaved(_controller.text);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final parsed = parseBypassDomains(_controller.text);
    final dirty = _controller.text.trim() != widget.value.trim();
    final tooLong = _controller.text.length > maxBypassCharacters;

    return _Panel(
      accent: SgColors.teal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconBox(icon: Icons.alt_route_rounded, color: SgColors.teal),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Свои домены — через локацию',
                      style: TextStyle(
                        color: c.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Сайты из этого списка всегда открываются через '
                      'выбранную локацию.',
                      style: TextStyle(color: c.faint, fontSize: 12, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: c.pill,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextField(
              controller: _controller,
              minLines: 2,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              style: TextStyle(color: c.ink, fontSize: 13),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: 't.me, rutracker.org',
                hintStyle: TextStyle(color: c.faint, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Через запятую: t.me, rutracker.org. Поддомены входят. Можно '
            'вставить ссылку — останется только адрес.',
            style: TextStyle(color: c.faint, fontSize: 11.5, height: 1.35),
          ),
          const SizedBox(height: 4),
          Text(
            'Изменения применяются сразу после нажатия «Сохранить».',
            style: TextStyle(color: c.faint, fontSize: 11.5, height: 1.35),
          ),
          if (tooLong) ...[
            const SizedBox(height: 8),
            _Inline(
              icon: Icons.info_outline_rounded,
              color: SgColors.red,
              text: 'Слишком длинный список: сохранятся только первые '
                  '$maxBypassDomains доменов.',
            ),
          ],
          if (parsed.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final domain in parsed.take(12))
                  _DomainChip(label: domain, tunnel: true),
                if (parsed.length > 12)
                  _DomainChip(label: '+${parsed.length - 12}', tunnel: false),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _Inline(
                  icon: parsed.isEmpty
                      ? Icons.info_outline_rounded
                      : Icons.bolt_rounded,
                  color: parsed.isEmpty ? c.faint : SgColors.teal,
                  text: parsed.isEmpty
                      ? 'Список пуст: трафик идёт по обычным правилам'
                      : 'Готово к работе: ${parsed.length} '
                            '${_plural(parsed.length)} — через локацию',
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: dirty && !_saving ? _save : null,
                child: Text(_saving ? '…' : 'Сохранить'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _plural(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return 'домен';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'домена';
    }
    return 'доменов';
  }
}

class _DomainChip extends StatelessWidget {
  const _DomainChip({required this.label, required this.tunnel});

  final String label;
  final bool tunnel;

  @override
  Widget build(BuildContext context) {
    final color = tunnel ? SgColors.blue : SgColors.violet;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Inline extends StatelessWidget {
  const _Inline({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: c.ink,
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

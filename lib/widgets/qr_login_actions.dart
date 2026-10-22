import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/qr_scan_screen.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import 'qr_login_panel.dart';

/// The two halves of signing in somewhere else.
///
/// Which of them a device offers is a property of the device, not of the user:
/// a desktop can only show a code, a phone can also read one. They are kept
/// together in one widget so the pair cannot drift apart between the sign-in
/// screen and the settings.
class QrLoginButtons extends StatelessWidget {
  const QrLoginButtons({super.key, this.authScreen = false});

  /// On the sign-in screen the buttons sit under the other options and take the
  /// full width; elsewhere they share a row inside a card.
  final bool authScreen;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.qrLoginAvailable) return const SizedBox.shrink();

    final scan = state.canScanQrCode
        ? SgActionTile(
            icon: Icons.qr_code_scanner_rounded,
            label: 'Войти по QR',
            color: SgColors.teal,
            enabled: !state.busy && !state.qrBusy,
            onTap: () => openQrScanner(context),
          )
        : null;
    final show = SgActionTile(
      icon: Icons.qr_code_2_rounded,
      label: 'Показать QR',
      color: SgColors.violet,
      enabled: !state.busy && !state.qrBusy,
      onTap: () => openQrLoginSheet(context, inline: authScreen),
    );

    if (authScreen) {
      return Column(
        children: [
          if (scan != null) ...[scan, const SizedBox(height: 10)],
          show,
        ],
      );
    }

    return Row(
      children: [
        if (scan != null) ...[Expanded(child: scan), const SizedBox(width: 10)],
        Expanded(child: show),
      ],
    );
  }
}

/// A compact action, sized to sit under a list row rather than beside a form.
class SgActionTile extends StatelessWidget {
  const SgActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: c.pill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: c.line),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the camera and signs this device in with whatever it reads.
Future<void> openQrScanner(BuildContext context) async {
  final state = context.read<AppState>();
  final raw = await Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => const QrScanScreen()),
  );
  if (raw == null || raw.isEmpty) return;
  await state.signInWithQrCode(raw);
}

/// Shows the code this device offers to another one.
///
/// With [inline] the code is rendered by the caller in place — the sign-in
/// screen puts it directly under the buttons — and without it the code opens in
/// a sheet, which is what the settings need.
Future<void> openQrLoginSheet(
  BuildContext context, {
  bool inline = false,
}) async {
  final state = context.read<AppState>();
  await state.showQrLogin();
  if (inline) return;
  if (!context.mounted || state.qrSession == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: QrLoginPanel(
          compact: true,
          onClose: () {
            state.hideQrLogin();
            Navigator.of(sheetContext).pop();
          },
        ),
      ),
    ),
  );
  // The sheet can also be dismissed by dragging it away or by the back button,
  // and the polling must stop in every one of those cases.
  state.hideQrLogin();
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';

/// The code that signs another device in, and what is happening to it.
///
/// One widget serves both places the code is offered — the block under the
/// sign-in buttons and the sheet opened from the settings — because it is the
/// same object either way: a session identifier rendered as a QR, refreshed
/// while it is on screen, and replaced by a confirmation the moment the session
/// is taken.
class QrLoginPanel extends StatefulWidget {
  const QrLoginPanel({super.key, this.onClose, this.compact = false});

  /// Called when the user dismisses the code; `null` leaves no way out.
  final VoidCallback? onClose;

  /// Tightens the layout for a sheet on a short screen.
  final bool compact;

  @override
  State<QrLoginPanel> createState() => _QrLoginPanelState();
}

class _QrLoginPanelState extends State<QrLoginPanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Only the countdown needs a frame a second; everything else in the panel
    // arrives through the state, so this is deliberately the smallest possible
    // source of repaints.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);
    final session = state.qrSession;

    if (session == null) {
      return const SizedBox.shrink();
    }

    final solved = state.qrSolved;
    final remaining = _secondsLeft(state.qrRotatesAt);
    final fraction = remaining / AppState.qrRotation.inSeconds;

    return Container(
      padding: EdgeInsets.all(widget.compact ? 14 : 18),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: (solved ? SgColors.green : SgColors.violet).withValues(
            alpha: 0.35,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                solved ? Icons.check_circle_rounded : Icons.qr_code_2_rounded,
                color: solved ? SgColors.green : SgColors.violet,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  solved ? 'Готово' : 'Вход по QR-коду',
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (widget.onClose != null)
                IconButton(
                  onPressed: widget.onClose,
                  icon: Icon(Icons.close_rounded, color: c.faint, size: 20),
                  tooltip: 'Закрыть',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (solved) ...[
            Text(
              state.qrStatus ?? 'Устройство подключено',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 13, height: 1.4),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                // Always black on white: an inverted code stumps most phone
                // cameras, and a theme-aware colour scheme would produce one on
                // every dark background.
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: QrImageView(
                data: session.link,
                version: QrVersions.auto,
                size: widget.compact ? 176 : 208,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF101425),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF101425),
                ),
                errorStateBuilder: (context, error) => SizedBox(
                  width: widget.compact ? 176 : 208,
                  height: widget.compact ? 176 : 208,
                  child: Center(
                    child: Text(
                      'Не удалось построить код',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.faint, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: fraction.clamp(0, 1),
                minHeight: 4,
                backgroundColor: c.line,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  SgColors.violet,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.qrStatus ?? _instruction(state),
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Код обновится через $remaining с',
              style: TextStyle(color: c.faint, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }

  /// What the person holding the other device has to do.
  ///
  /// Which way round that is depends on who is signed in: a code shown from
  /// inside the application is scanned by a device that wants in, while a code
  /// shown on the sign-in screen is scanned by a device that already is.
  String _instruction(AppState state) => state.user == null
      ? 'Отсканируйте код в приложении, где вы уже вошли'
      : 'Отсканируйте код на устройстве, которое хотите подключить';

  int _secondsLeft(DateTime? deadline) {
    if (deadline == null) return 0;
    final left = deadline.difference(DateTime.now()).inSeconds;
    return left < 0 ? 0 : left;
  }
}

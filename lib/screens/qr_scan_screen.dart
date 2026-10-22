import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/qr_link.dart';
import '../theme/app_colors.dart';

/// The camera, pointed at somebody else's screen.
///
/// Only the phone side of a QR sign-in needs this; a desktop shows the code
/// instead. The scanner closes itself as soon as it has read one, returning the
/// raw text to the caller, because the interesting decision — approve or wait —
/// belongs to the sign-in flow rather than to the camera.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    // Without this the same code fires dozens of times a second, and every one
    // of those is a network round trip.
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// Set the moment a code is accepted, to swallow anything that arrives while
  /// the screen is on its way out.
  bool _accepted = false;
  bool _torch = false;
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_accepted) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .firstWhere((value) => value != null && value.isNotEmpty, orElse: () => null);
    if (raw == null) return;
    if (qrSessionIdFromLink(raw) == null) {
      // Anything that is not ours is worth saying out loud: otherwise a wrong
      // QR code looks like a camera that simply does not work.
      if (mounted) setState(() => _problem = 'Это не код ScaleGuard');
      return;
    }
    _accepted = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.no_photography_rounded,
                      color: Colors.white70,
                      size: 42,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Не удалось включить камеру.\nРазрешите доступ к камере в '
                      'настройках системы и попробуйте снова.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // A window to aim with, and a scrim that keeps the rest out of the way.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 236,
                height: 236,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: SgColors.violet, width: 3),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      tooltip: 'Отмена',
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () async {
                        await _controller.toggleTorch();
                        if (mounted) setState(() => _torch = !_torch);
                      },
                      icon: Icon(
                        _torch
                            ? Icons.flashlight_on_rounded
                            : Icons.flashlight_off_rounded,
                        color: Colors.white,
                      ),
                      tooltip: 'Фонарик',
                    ),
                  ],
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 34),
                  child: Column(
                    children: [
                      Text(
                        _problem ??
                            'Наведите камеру на QR-код в приложении на другом '
                                'устройстве',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _problem != null
                              ? const Color(0xFFFF8098)
                              : Colors.white,
                          fontSize: 14,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Вход выполняется без пароля',
                        style: TextStyle(
                          color: c.faint,
                          fontSize: 12,
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

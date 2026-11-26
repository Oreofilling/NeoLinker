/// Live QR scanner for macOS.
///
/// The `camera` plugin family has no macOS implementation at any version,
/// so the Windows stills loop in qr_camera_scanner.dart cannot be reused
/// here. mobile_scanner detects barcodes straight off the camera with
/// Apple Vision and hands over the raw text; this widget keeps the same
/// contract as the Windows scanner: exactly one [onDecoded] for the first
/// spec-conforming QR, then quiet. Text that is not a device code (a
/// packaging label, a payment QR…) is just another empty frame.
///
/// A camera failure renders the muted "camera unavailable" surface — the
/// guide page's upload mode stays the fallback for machines without a
/// camera, as it does on Windows.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:neolinker_ui/neolinker_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../provisioning/device_qr_uri.dart';
import 'qr_viewfinder.dart';

/// Builds the surface that emits raw barcode text. Tests inject a fake
/// that calls `emit` with scripted text; production uses
/// [macVisionScanner].
typedef QrRawScannerBuilder = Widget Function(
  BuildContext context,
  void Function(String rawText) emit,
);

/// Production raw source: mobile_scanner's live preview. While the camera
/// starts, and when it cannot be opened at all, the surface shows the same
/// muted camera placeholder the Windows scanner uses.
Widget macVisionScanner(
  BuildContext context,
  void Function(String rawText) emit,
) {
  final c = context.nl;
  final l = AppLocalizations.of(context)!;
  return MobileScanner(
    onDetect: (capture) {
      final barcodes = capture.barcodes;
      if (barcodes.isEmpty) return;
      final rawText = barcodes.first.rawValue;
      if (rawText != null) emit(rawText);
    },
    placeholderBuilder: (context) =>
        _cameraPlaceholder(c, Icons.videocam_outlined),
    errorBuilder: (context, error) {
      debugPrint('qr scanner: live camera failed: ${error.errorCode}');
      return _cameraPlaceholder(
        c,
        Icons.videocam_off_outlined,
        hint: l.qrCameraError,
      );
    },
  );
}

Widget _cameraPlaceholder(NLColors c, IconData icon, {String? hint}) {
  final Widget content;
  if (hint == null) {
    content = Icon(icon, size: 34, color: c.mutedForeground);
  } else {
    content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: c.mutedForeground),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: c.mutedForeground),
          ),
        ],
      ),
    );
  }
  return ColoredBox(
    color: c.muted.withValues(alpha: 0.12),
    child: Center(child: content),
  );
}

/// Camera card for the macOS leg: a live scanner surface under the shared
/// viewfinder brackets, with the same quiet status line as the Windows
/// scanner.
class QrLiveScanner extends StatefulWidget {
  const QrLiveScanner({
    super.key,
    required this.onDecoded,
    this.rawScannerBuilder,
  });

  final void Function(DeviceQrUri uri) onDecoded;

  /// Injected by tests; defaults to [macVisionScanner].
  final QrRawScannerBuilder? rawScannerBuilder;

  @override
  State<QrLiveScanner> createState() => _QrLiveScannerState();
}

class _QrLiveScannerState extends State<QrLiveScanner> {
  bool _done = false;

  void _onRawText(String rawText) {
    // Fire once: later detections (the same code re-read, a second code)
    // are ignored — the parent advances and disposes this widget.
    if (_done || !mounted) return;
    final uri = DeviceQrUri.tryParse(rawText);
    if (uri == null) return;
    _done = true;
    widget.onDecoded(uri);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nl;
    final l = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(NLRadii.radiusLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                (widget.rawScannerBuilder ?? macVisionScanner)(
                  context,
                  _onRawText,
                ),
                // Viewfinder brackets sit above the preview so users aim
                // the QR at a fixed spot.
                const Positioned.fill(child: QrViewfinderBrackets()),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: c.ring,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.qrScanHint,
                    style: TextStyle(fontSize: 11, color: c.mutedForeground),
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

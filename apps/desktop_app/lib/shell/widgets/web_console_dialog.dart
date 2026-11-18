import 'package:flutter/material.dart';
import 'package:neolinker_ui/neolinker_ui.dart';

/// Full-screen device console dialog, the single embedded-console surface
/// for every entry point (NE503 LAN row from the scan table, NE301 web
/// hold after the softAP join): header with the device label, selectable
/// URL and close button; body with the embedded console. Without the
/// embed seam the URL stays selectable so the browser fallback remains
/// reachable.
class WebConsoleDialog extends StatelessWidget {
  const WebConsoleDialog({
    super.key,
    required this.title,
    required this.url,
    this.embed,
  });

  /// Device label shown in the header (model hint / MAC suffix).
  final String title;

  /// Console entry address, shown selectable in the header.
  final Uri url;

  /// Embedded console surface; null falls back to the selectable URL.
  final Widget? embed;

  /// Opens the dialog over [context] — the one-liner both call sites use.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required Uri url,
    Widget? embed,
  }) =>
      showDialog<void>(
        context: context,
        builder: (_) => WebConsoleDialog(title: title, url: url, embed: embed),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.nl;
    return Dialog.fullscreen(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.language, size: 16, color: c.accentCyan),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: NLType.cardTitle.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: SelectableText(
                    url.toString(),
                    maxLines: 1,
                    style: NLType.mono.copyWith(color: c.mutedForeground),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: embed ??
                Center(
                  child: SelectableText(url.toString(), style: NLType.mono),
                ),
          ),
        ],
      ),
    );
  }
}

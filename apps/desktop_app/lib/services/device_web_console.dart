/// Embedded device web console for web mode: the console renders inside
/// the app (WebView2 via flutter_inappwebview) instead of a browser tab.
///
/// The controller carries only the builder seam — mirroring
/// [DeviceWebOpener]: the production builder is wired once at app
/// assembly (app.dart) and tests inject a fake, because the default must
/// never instantiate a real WebView2 inside a widget test (the suite runs
/// on the Windows host too). Copy is NOT part of the seam: the widget
/// reads the ARB strings through its own context, so callers stay plain.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/app_localizations.dart';

/// Builds the embedded console surface for [url]. Null from
/// [defaultWebConsoleBuilder] means "embed unavailable" and the caller
/// falls back to the browser hold panel.
typedef WebConsoleBuilder = Widget Function(Uri url);

/// Production builder: Windows-only. Other platforms return null and web
/// mode keeps the system-browser behavior.
WebConsoleBuilder? defaultWebConsoleBuilder() {
  if (!Platform.isWindows) return null;
  return (url) => DeviceWebConsole(url: url);
}

/// App-scoped WebView2 environment, shared by every console surface.
///
/// A per-instance environment breaks on rapid reopen: WebView2 keeps the
/// user-data folder locked while the previous browser process winds down,
/// and a fresh WebViewEnvironment.create for the same folder fails inside
/// that window (the "console could not start" panel). One environment per
/// app run sidesteps the lock entirely; dialog open/close only mounts
/// InAppWebView instances on it.
WebViewEnvironment? _sharedEnvironment;
Future<WebViewEnvironment?>? _sharedCreating;
Object? _sharedError;

Future<WebViewEnvironment?> _obtainSharedEnvironment() {
  if (_sharedEnvironment != null) return Future.value(_sharedEnvironment);
  return _sharedCreating ??= _createSharedEnvironment();
}

Future<WebViewEnvironment?> _createSharedEnvironment() async {
  final appData = Platform.environment['APPDATA'];
  final profile = appData == null ? null : '$appData\\NeoLinker\\WebView2';
  try {
    final environment = await WebViewEnvironment.create(
      // Device consoles ride the nginx 443 entry with a self-signed
      // cert; this WebView2 profile is console-only (own userDataFolder,
      // never pointed at arbitrary sites), so skip cert validation here.
      settings: WebViewEnvironmentSettings(
        userDataFolder: profile,
        additionalBrowserArguments: '--ignore-certificate-errors',
      ),
    );
    _sharedEnvironment = environment;
    return environment;
  } catch (error) {
    _sharedError = error;
    return null;
  } finally {
    _sharedCreating = null;
  }
}

/// Retry only makes sense after a failure — a live environment is kept.
Future<WebViewEnvironment?> _retrySharedEnvironment() async {
  if (_sharedEnvironment != null) return _sharedEnvironment;
  _sharedError = null;
  return _obtainSharedEnvironment();
}

/// WebView2 surface with a corner reload chip — after the device's idle
/// sleep a reload is the wake action for the held link.
class DeviceWebConsole extends StatefulWidget {
  const DeviceWebConsole({super.key, required this.url});

  final Uri url;

  @override
  State<DeviceWebConsole> createState() => _DeviceWebConsoleState();
}

class _DeviceWebConsoleState extends State<DeviceWebConsole> {
  InAppWebViewController? _webController;

  /// The current attempt's main document failed to load (network level —
  /// refused/unroutable/timeout, mapped by the plugin from WebView2's
  /// NavigationCompleted). The surface swaps to the offline panel; retry
  /// remounts the webview for a fresh initial load.
  bool _loadFailed = false;

  /// Some navigation of this attempt already succeeded: later in-page
  /// navigation failures keep the current document (normal browser
  /// behavior) instead of yanking the panel over a transient link error.
  bool _loadedOk = false;

  /// Remount counter: a retry discards the failed webview (its controller
  /// dies with it) and runs a fresh initial request.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_attachEnvironment());
  }

  Future<void> _attachEnvironment() async {
    await _obtainSharedEnvironment();
    if (mounted) setState(() {});
  }

  Future<void> _retryEnvironment() async {
    await _retrySharedEnvironment();
    if (mounted) setState(() {});
  }

  void _retryLoad() {
    setState(() {
      _loadFailed = false;
      _loadedOk = false;
      _attempt++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;
    if (_sharedEnvironment == null) {
      if (_sharedError != null) {
        // WebView2 runtime missing/broken: the panel's browser button is
        // the real fallback; this surface just explains and offers a retry.
        return _consoleNoticePanel(
          theme,
          text: l.webConsoleEnvFailed,
          actionLabel: l.webConsoleRetry,
          onAction: _retryEnvironment,
        );
      }
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_loadFailed) {
      return _consoleNoticePanel(
        theme,
        text: l.webConsoleLoadFailed,
        actionLabel: l.webConsoleRetry,
        onAction: _retryLoad,
      );
    }
    return Stack(
      children: [
        InAppWebView(
          key: ValueKey('${widget.url}#$_attempt'),
          webViewEnvironment: _sharedEnvironment,
          initialUrlRequest: URLRequest(url: WebUri(widget.url.toString())),
          initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
          onWebViewCreated: (controller) => _webController = controller,
          onLoadStop: (controller, url) => _loadedOk = true,
          onReceivedError: (controller, request, error) {
            // Only a failed FIRST load swaps the panel: once a document is
            // up, later navigation errors keep what is on screen.
            if (_loadedOk || request.isForMainFrame == false) return;
            if (mounted) setState(() => _loadFailed = true);
          },
        ),
        // Corner reload chip: wakes the console after an idle sleep.
        Positioned(
          top: 8,
          right: 8,
          child: Tooltip(
            message: l.webConsoleReload,
            child: Material(
              color: theme.colorScheme.surface,
              shape: const CircleBorder(),
              elevation: 2,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _webController?.reload(),
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Icon(
                    Icons.refresh,
                    size: 15,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Shared notice panel for the two console-unavailable causes (WebView2
  /// environment failure / main document load failure): one line of copy
  /// plus a single retry action.
  Widget _consoleNoticePanel(
    ThemeData theme, {
    required String text,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

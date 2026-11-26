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
import 'device_web_opener.dart';

/// Builds the embedded console surface for [url]. Null from
/// [defaultWebConsoleBuilder] means "embed unavailable" and the caller
/// falls back to the browser hold panel.
typedef WebConsoleBuilder = Widget Function(Uri url);

/// Production builder for Windows (WebView2) and macOS (WKWebView). Other
/// platforms return null and web mode keeps the system-browser behavior.
WebConsoleBuilder? defaultWebConsoleBuilder() {
  if (!Platform.isWindows && !Platform.isMacOS) return null;
  return (url) => DeviceWebConsole(url: url);
}

/// Decides a server-trust (certificate) challenge raised while loading the
/// device console: the host of the console URL we opened ourselves is
/// trusted — device consoles ship self-signed certificates by design — and
/// anything else (a redirect, a foreign host) fails closed. This is the
/// macOS counterpart of the Windows environment's
/// `--ignore-certificate-errors`, scoped to that one host.
ServerTrustAuthResponse serverTrustResponseFor(
  Uri url,
  ServerTrustChallenge challenge,
) {
  final trusted = challenge.protectionSpace.host == url.host;
  return ServerTrustAuthResponse(
    action: trusted
        ? ServerTrustAuthResponseAction.PROCEED
        : ServerTrustAuthResponseAction.CANCEL,
  );
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
  const DeviceWebConsole({
    super.key,
    required this.url,
    this.opener = openDeviceWebPage,
  });

  final Uri url;

  /// Launches the console in the system browser — the way out when the
  /// embedded surface cannot load. Injectable so tests never shell out.
  final DeviceWebOpener opener;

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

  /// Only Windows needs the shared WebView2 environment; WKWebView has no
  /// environment to create, so the macOS surface mounts directly.
  static final bool _envGated = Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (_envGated) unawaited(_attachEnvironment());
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
    if (_envGated && _sharedEnvironment == null) {
      if (_sharedError != null) {
        // WebView2 runtime missing/broken: explain, and offer both a retry
        // and the browser — the embedded surface is not the only way out.
        return _consoleNoticePanel(
          theme,
          text: l.webConsoleEnvFailed,
          retryLabel: l.webConsoleRetry,
          onRetry: _retryEnvironment,
          browserLabel: l.webHoldOpenBrowser,
          onBrowser: _openInBrowser,
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
      // A failed load must never be a dead end: the LAN console dialog has
      // no other browser button once the host probe succeeded.
      return _consoleNoticePanel(
        theme,
        text: l.webConsoleLoadFailed,
        retryLabel: l.webConsoleRetry,
        onRetry: _retryLoad,
        browserLabel: l.webHoldOpenBrowser,
        onBrowser: _openInBrowser,
      );
    }
    return Stack(
      children: [
        InAppWebView(
          key: ValueKey('${widget.url}#$_attempt'),
          webViewEnvironment: _envGated ? _sharedEnvironment : null,
          initialUrlRequest: URLRequest(url: WebUri(widget.url.toString())),
          initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
          // macOS: device consoles ride self-signed certificates, so the
          // host of the URL we opened is trusted. Attached only there —
          // the Windows plugin implements the callback too, and Windows
          // relies on the environment-level flag instead.
          onReceivedServerTrustAuthRequest: _envGated
              ? null
              : (controller, challenge) =>
                    serverTrustResponseFor(widget.url, challenge),
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

  /// Best effort: the browser owns everything after the launch.
  void _openInBrowser() {
    unawaited(widget.opener(widget.url));
  }

  /// Shared notice panel for the two console-unavailable causes (WebView2
  /// environment failure / main document load failure): one line of copy,
  /// a retry action, and the browser as the way out.
  Widget _consoleNoticePanel(
    ThemeData theme, {
    required String text,
    required String retryLabel,
    required VoidCallback onRetry,
    required String browserLabel,
    required VoidCallback onBrowser,
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
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton(onPressed: onRetry, child: Text(retryLabel)),
              TextButton(onPressed: onBrowser, child: Text(browserLabel)),
            ],
          ),
        ],
      ),
    );
  }
}

// Embedded device console: host-scoped certificate trust and the platform
// default of the console builder. The widget itself is never pumped here —
// it mounts a real platform view (WebView2 on Windows, WKWebView on macOS).
library;

import 'dart:io' show Platform;

import 'package:desktop_app/services/device_web_console.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

ServerTrustChallenge _challengeFor(String host) => ServerTrustChallenge(
      protectionSpace: URLProtectionSpace(
        host: host,
        protocol: 'https',
        port: 443,
      ),
    );

void main() {
  group('serverTrustResponseFor', () {
    final console = Uri.parse('https://192.168.93.72/');

    test('trusts the self-signed cert of the device host we opened', () {
      final response = serverTrustResponseFor(
        console,
        _challengeFor('192.168.93.72'),
      );
      expect(response.action, ServerTrustAuthResponseAction.PROCEED);
    });

    test('fails closed for any other host (redirect, foreign page)', () {
      for (final host in ['example.com', '192.168.93.73', '']) {
        final response = serverTrustResponseFor(console, _challengeFor(host));
        expect(
          response.action,
          ServerTrustAuthResponseAction.CANCEL,
          reason: host,
        );
      }
    });
  });

  group('defaultWebConsoleBuilder', () {
    // The suite runs on Windows/Linux/macOS CI hosts alike: the builder is
    // engaged where an embedded web view exists (WebView2 / WKWebView) and
    // null elsewhere, where web mode keeps the system browser.
    test('follows the host platform', () {
      final builder = defaultWebConsoleBuilder();
      final embedded = Platform.isWindows || Platform.isMacOS;
      expect(builder, embedded ? isNotNull : isNull);
    });
  });
}

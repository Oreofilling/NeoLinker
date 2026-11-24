// macOS Wi-Fi scan/join surface over the mac_wlan channel, driven through
// an injected channel runner (the suite runs on Linux/Windows hosts — the
// joiner's `enabled` seam forces the macOS flow, because unlike
// WinWlanJoiner there is no on-box smoke round for this code path yet).
library;

import 'package:ap_discovery_adapter/ap_discovery_adapter.dart';
import 'package:desktop_app/services/mac_wlan.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Routes method names to scripted handlers and records every call.
MacWlanRunner _router(
  Map<String, Object? Function(Map<Object?, Object?>)> routes, [
  void Function(String method)? onCall,
]) {
  return (method, args) {
    onCall?.call(method);
    final handler = routes[method];
    if (handler == null) {
      throw StateError('unexpected mac_wlan call: $method');
    }
    return Future.sync(() => handler(args ?? const {}));
  };
}

void main() {
  group('macWlanScanOnce', () {
    test('maps CoreWLAN rows onto the WlanNetwork quality scale', () async {
      final rows = [
        {'ssid': 'NE101_2001CA', 'rssi': -60, 'security': 'open'},
        {'ssid': '', 'rssi': -100, 'security': 'wpa2'},
        {'ssid': 'NE301_AABBCC', 'rssi': -40, 'security': 'open'},
      ];
      final networks =
          await macWlanScanOnce(runner: _router({'scan': (_) => rows}));
      expect(networks, isNotNull);
      expect(networks!.length, 3);
      expect(networks[0].ssid, 'NE101_2001CA');
      expect(networks[0].signalQuality, 80);
      // The quality scale round-trips through rssiEstimate.
      expect(networks[0].rssiEstimate, -60);
      expect(networks[1].ssid, '');
      expect(networks[1].signalQuality, 0);
      // -40 dBm saturates the 0-100 scale.
      expect(networks[2].signalQuality, 100);
      expect(networks.every((n) => n.profileName.isEmpty), isTrue);
    });

    test('quiet pass (null) on no interface or location denial', () async {
      for (final code in ['no_interface', 'location_denied']) {
        Future<Object?> runner(String method, Map<Object?, Object?>? args) async {
          throw PlatformException(code: code);
        }
        expect(await macWlanScanOnce(runner: runner), isNull,
            reason: code);
      }
    });

    test('quiet pass on a null scan result', () async {
      final networks =
          await macWlanScanOnce(runner: _router({'scan': (_) => null}));
      expect(networks, isNull);
    });

    test('rethrows unrelated channel errors for the poll loop to swallow',
        () async {
      Future<Object?> runner(String method, Map<Object?, Object?>? args) async {
        throw PlatformException(code: 'boom');
      }
      expect(() => macWlanScanOnce(runner: runner),
          throwsA(isA<PlatformException>()));
    });
  });

  group('MacWlanJoiner.capture', () {
    test('records the current SSID as its own restore profile', () async {
      final joiner = MacWlanJoiner(
        runner: _router({'currentSsid': (_) => 'TP-LINK-5G'}),
        enabled: true,
      );
      final point = await joiner.capture();
      expect(point, isNotNull);
      expect(point!.ssid, 'TP-LINK-5G');
      // macOS has no profile store: the SSID doubles as the restore key.
      expect(point.profileName, 'TP-LINK-5G');
    });

    test('returns null when not associated', () async {
      final joiner = MacWlanJoiner(
        runner: _router({'currentSsid': (_) => null}),
        enabled: true,
      );
      expect(await joiner.capture(), isNull);
      final empty =
          MacWlanJoiner(runner: _router({'currentSsid': (_) => ''}), enabled: true);
      expect(await empty.capture(), isNull);
    });

    test('inert off macOS: no channel calls, null result', () async {
      var called = false;
      final joiner = MacWlanJoiner(
        runner: _router({}, (_) { called = true; }),
      );
      expect(await joiner.capture(), isNull);
      expect(called, isFalse);
    });
  });

  group('MacWlanJoiner.join', () {
    test('associate then gateway probe, with step callbacks', () async {
      final calls = <String>[];
      final steps = <String>[];
      final joiner = MacWlanJoiner(
        runner: _router({
          'join': (_) => true,
          'currentSsid': (_) => 'NE101_2001CA',
        }, calls.add),
        probeGateway: (_, __) async => true,
        enabled: true,
      );
      await joiner.join(
        'NE101_2001CA',
        gatewayHost: '192.168.1.1',
        gatewayPort: 80,
        onStep: steps.add,
      );
      expect(calls.first, 'join');
      expect(calls, contains('currentSsid'));
      expect(steps, [
        'requesting association',
        'waiting association',
        'waiting gateway',
      ]);
    });

    test('refused association maps to join_connect_failed', () async {
      final joiner = MacWlanJoiner(
        runner: _router({'join': (_) => false}),
        enabled: true,
      );
      await expectLater(
        joiner.join('NE101_2001CA'),
        throwsA(isA<ApJoinException>().having(
            (e) => e.codeName, 'code', kJoinConnectFailed)),
      );
    });

    test('channel error maps to join_connect_failed', () async {
      Future<Object?> boom(String method, Map<Object?, Object?>? args) async {
        throw PlatformException(code: 'no_interface');
      }
      final joiner = MacWlanJoiner(runner: boom, enabled: true);
      await expectLater(
        joiner.join('NE101_2001CA'),
        throwsA(isA<ApJoinException>().having(
            (e) => e.codeName, 'code', kJoinConnectFailed)),
      );
    });

    test('association never landing maps to join_timeout', () async {
      final joiner = MacWlanJoiner(
        runner: _router({
          'join': (_) => true,
          // Auto-join raced us onto another network.
          'currentSsid': (_) => 'HomeNetwork',
        }),
        probeGateway: (_, __) async => true,
        enabled: true,
      );
      await expectLater(
        joiner.join('NE101_2001CA', timeout: const Duration(milliseconds: 60)),
        throwsA(isA<ApJoinException>()
            .having((e) => e.codeName, 'code', kJoinTimeout)),
      );
    });

    test('silent gateway maps to gateway_timeout', () async {
      final joiner = MacWlanJoiner(
        runner: _router({
          'join': (_) => true,
          'currentSsid': (_) => 'NE101_2001CA',
        }),
        probeGateway: (_, __) async => false,
        enabled: true,
      );
      await expectLater(
        joiner.join('NE101_2001CA', timeout: const Duration(milliseconds: 60)),
        throwsA(isA<ApJoinException>().having(
            (e) => e.codeName, 'code', kJoinGatewayTimeout)),
      );
    });

    test('refuses with no_wlan_interface off macOS, no channel calls',
        () async {
      var called = false;
      final joiner = MacWlanJoiner(runner: _router({}, (_) { called = true; }));
      await expectLater(
        joiner.join('NE101_2001CA'),
        throwsA(isA<ApJoinException>().having(
            (e) => e.codeName, 'code', kJoinNoInterface)),
      );
      expect(called, isFalse);
    });
  });

  group('MacWlanJoiner.restore', () {
    test('re-associates with the saved SSID', () async {
      final joins = <Map<Object?, Object?>?>[];
      final joiner = MacWlanJoiner(
        runner: _router({
          'join': (args) {
            joins.add(args);
            return true;
          },
        }),
        enabled: true,
      );
      await joiner.restore(const WlanRestorePoint(
          ssid: 'TP-LINK-5G', profileName: 'TP-LINK-5G'));
      expect(joins, [
        {'ssid': 'TP-LINK-5G'},
      ]);
    });

    test('plain-disconnects when the point has no restore SSID', () async {
      final calls = <String>[];
      final joiner = MacWlanJoiner(
        runner: _router({'disconnect': (_) => true}, calls.add),
        enabled: true,
      );
      await joiner.restore(null);
      await joiner
          .restore(const WlanRestorePoint(ssid: '', profileName: null));
      expect(calls, ['disconnect', 'disconnect']);
    });

    test('refused re-association maps to restore_failed', () async {
      final joiner = MacWlanJoiner(
        runner: _router({'join': (_) => false}),
        enabled: true,
      );
      await expectLater(
        joiner.restore(
            const WlanRestorePoint(ssid: 'TP-LINK-5G', profileName: 'TP-LINK-5G')),
        throwsA(isA<ApJoinException>().having(
            (e) => e.codeName, 'code', kJoinRestoreFailed)),
      );
    });

    test('inert off macOS', () async {
      var called = false;
      final joiner = MacWlanJoiner(runner: _router({}, (_) { called = true; }));
      await joiner.restore(
          const WlanRestorePoint(ssid: 'TP-LINK-5G', profileName: 'TP-LINK-5G'));
      expect(called, isFalse);
    });
  });

  group('assembly defaults', () {
    // The suite never runs on macOS, so both factories report their
    // off-platform value here: null keeps the Windows wlanapi default.
    test('defaultMacApJoiner and scanner are null off macOS', () {
      expect(defaultMacApJoiner(), isNull);
      expect(defaultMacApScanner(), isNull);
    });
  });
}

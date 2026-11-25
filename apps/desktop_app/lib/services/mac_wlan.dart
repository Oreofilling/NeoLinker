/// macOS Wi-Fi primitives over the `neolinker/mac_wlan` platform channel
/// (CoreWLAN in the Swift runner). The macOS counterpart of
/// [WinWlanJoiner]/[WinWlanScanner]: list visible device APs for the scan
/// page, associate the machine with the device softAP for the provisioning
/// session, and restore the previous Wi-Fi link afterwards.
///
/// Channel contract (see macos/Runner/AppDelegate.swift):
/// - `currentSsid` -> String? (null when not associated)
/// - `scan` -> List<{ssid: String, rssi: int (dBm)}> or
///   PlatformException `no_interface` / `location_denied`
/// - `join` {ssid, password?} -> bool (CoreWLAN associate, falling back to
///   `networksetup -setairportNetwork`)
/// - `disconnect` -> bool
///
/// The channel runner is constructor-injectable so tests drive the whole
/// surface with a plain closure — the workspace never mocks binary
/// messengers.
library;

import 'dart:async';
import 'dart:io';

import 'package:ap_discovery_adapter/ap_discovery_adapter.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

const MethodChannel _kMacWlanChannel = MethodChannel('neolinker/mac_wlan');

/// Poll cadence while waiting for the association to come up (mirrors
/// win_wlan_join.dart).
const Duration _kAssocPollInterval = Duration(milliseconds: 300);

/// Poll cadence while waiting for the gateway to answer TCP.
const Duration _kGatewayPollInterval = Duration(milliseconds: 500);

/// Per-attempt TCP connect timeout for the gateway probe.
const Duration _kProbeTimeout = Duration(seconds: 1);

/// Platform-channel runner seam; tests inject a closure.
typedef MacWlanRunner = Future<Object?> Function(
  String method,
  Map<Object?, Object?>? arguments,
);

Future<Object?> _defaultRunner(
  String method,
  Map<Object?, Object?>? arguments,
) =>
    _kMacWlanChannel.invokeMethod<Object?>(method, arguments);

/// Production joiner for the macOS assembly; null on other platforms (the
/// controller then falls back to the Windows default, which refuses early
/// off Windows).
ApJoiner? defaultMacApJoiner() =>
    Platform.isMacOS ? MacWlanJoiner() : null;

/// Production AP scanner for the macOS assembly; null on other platforms
/// (the source then falls back to the Windows default, which reports
/// nothing). macOS 10.15+ gates SSID scans behind Location Services — the
/// Swift side requests authorization, and a denial surfaces here as a
/// null pass (the AP channel reports nothing this cycle, QR/manual entry
/// still work).
Future<List<WlanNetwork>?> Function()? defaultMacApScanner() =>
    Platform.isMacOS ? () => macWlanScanOnce() : null;

/// One scan pass over CoreWLAN. Null when the radio/interface is missing
/// or the user denied location access — either way this poll cycle has no
/// AP channel verdict.
Future<List<WlanNetwork>?> macWlanScanOnce({MacWlanRunner? runner}) async {
  final call = runner ?? _defaultRunner;
  final Object? rows;
  try {
    rows = await call('scan', null);
  } on PlatformException catch (e) {
    if (e.code == 'no_interface' || e.code == 'location_denied') {
      return null;
    }
    rethrow;
  }
  if (rows == null) return null;
  return [
    for (final row in (rows as List<Object?>).cast<Map<Object?, Object?>>())
      WlanNetwork(
        ssid: row['ssid'] as String? ?? '',
        signalQuality: _dbmToSignalQuality(row['rssi'] as int? ?? -100),
        profileName: '',
      ),
  ];
}

/// CoreWLAN reports RSSI in dBm; [WlanNetwork] carries the Windows 0-100
/// quality scale (`rssiEstimate` inverts this on the way out).
int _dbmToSignalQuality(int dbm) => ((dbm + 100) * 2).clamp(0, 100);

Future<bool> _tcpProbeGateway(String host, int port) async {
  try {
    final socket = await Socket.connect(host, port, timeout: _kProbeTimeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// CoreWLAN implementation of [ApJoiner] behind the mac_wlan channel.
///
/// [enabled] resolves from the host platform by default; tests force it
/// true to exercise the flow (the suite never runs on macOS, and unlike
/// WinWlanJoiner there is no on-box smoke round yet — unit coverage is
/// this joiner's only safety net).
final class MacWlanJoiner implements ApJoiner {
  MacWlanJoiner({
    MacWlanRunner? runner,
    Future<bool> Function(String host, int port)? probeGateway,
    bool? enabled,
  })  : _runner = runner ?? _defaultRunner,
        _probeGateway = probeGateway ?? _tcpProbeGateway,
        _enabled = enabled ?? Platform.isMacOS;

  final MacWlanRunner _runner;
  final Future<bool> Function(String host, int port) _probeGateway;
  final bool _enabled;

  @override
  Future<WlanRestorePoint?> capture() async {
    if (!_enabled) return null;
    try {
      final ssid = await _runner('currentSsid', null) as String?;
      if (ssid == null || ssid.isEmpty) return null;
      // macOS has no profile store to name; restore re-associates by SSID,
      // so the SSID doubles as the profile name.
      return WlanRestorePoint(ssid: ssid, profileName: ssid);
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> join(
    String ssid, {
    Duration? timeout,
    String gatewayHost = '192.168.1.1',
    int gatewayPort = 80,
    String? password,
    void Function(String step)? onStep,
  }) async {
    if (!_enabled) {
      throw const ApJoinException(kJoinNoInterface, 'not running on macOS');
    }
    final deadline = DateTime.now().add(timeout ?? kDefaultJoinTimeout);

    onStep?.call('requesting association');
    try {
      final ok = await _runner('join', {
        'ssid': ssid,
        // Native side (AppDelegate.join) already accepts a password; null
        // keeps the open-network path.
        if (password != null) 'password': password,
      }) as bool? ?? false;
      if (!ok) {
        throw const ApJoinException(
          kJoinConnectFailed,
          'association command refused',
        );
      }
    } on PlatformException catch (e) {
      throw ApJoinException(kJoinConnectFailed, 'join channel: ${e.code}');
    }

    // The associate command returns before the link settles: poll the
    // association by SSID (matching the SSID rules out "connected to
    // something else" — the auto-join service may race us).
    onStep?.call('waiting association');
    var associated = false;
    while (!associated && DateTime.now().isBefore(deadline)) {
      try {
        final current = await _runner('currentSsid', null) as String?;
        associated = current == ssid;
      } on PlatformException {
        associated = false;
      }
      if (!associated) {
        await Future<void>.delayed(_kAssocPollInterval);
      }
    }
    if (!associated) {
      throw ApJoinException(kJoinTimeout, 'not associated with $ssid');
    }

    // DHCP runs after association; the operative readiness test is the
    // device actually answering on the gateway port (the same TCP path
    // the HTTP transport will use).
    onStep?.call('waiting gateway');
    var reachable = false;
    while (!reachable && DateTime.now().isBefore(deadline)) {
      reachable = await _probeGateway(gatewayHost, gatewayPort);
      if (!reachable) {
        await Future<void>.delayed(_kGatewayPollInterval);
      }
    }
    if (!reachable) {
      throw ApJoinException(
        kJoinGatewayTimeout,
        'gateway $gatewayHost:$gatewayPort did not answer',
      );
    }
  }

  @override
  Future<void> restore(WlanRestorePoint? point) async {
    if (!_enabled) return;
    final ssid = point?.profileName;
    try {
      if (ssid == null || ssid.isEmpty) {
        await _runner('disconnect', null);
        return;
      }
      // Best effort: re-associate with the saved SSID (macOS joins known
      // networks by SSID); an explicit refusal surfaces as restore_failed.
      final ok = await _runner('join', {'ssid': ssid}) as bool? ?? false;
      if (!ok) {
        throw const ApJoinException(
          kJoinRestoreFailed,
          're-association refused',
        );
      }
    } on PlatformException catch (e) {
      throw ApJoinException(kJoinRestoreFailed, 'restore channel: ${e.code}');
    }
  }
}

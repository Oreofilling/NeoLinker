/// macOS Wi-Fi primitives over the `neolinker/mac_wlan` platform channel
/// (CoreWLAN in the Swift runner). The macOS counterpart of
/// [WinWlanJoiner]/[WinWlanScanner]: list visible device APs for the scan
/// page, associate the machine with the device softAP for the provisioning
/// session, and restore the previous Wi-Fi link afterwards.
///
/// Channel contract (see macos/Runner/AppDelegate.swift):
/// - `currentSsid` -> String? (null when not associated)
/// - `scan` -> List<{ssid: String, rssi: int (dBm)}> holding every network
///   that exposes an SSID, or PlatformException `no_interface` /
///   `location_denied` / `location_pending` / `scan_failed`
/// - `join` {ssid, password?} -> bool (CoreWLAN associate, falling back to
///   `networksetup -setairportnetwork`)
/// - `disconnect` -> bool
/// - `adapterState` -> {present: bool, powerOn: bool} — whether a WLAN
///   interface exists and whether its radio is on. Needs no Location
///   Services, so the self-check can read it without a prompt.
/// - `locationStatus` -> [MacLocationStatus] name — the Location Services
///   verdict CoreWLAN gates SSIDs behind; reads it, never prompts.
///
/// The channel runner is constructor-injectable so tests drive the whole
/// surface with a plain closure — the workspace never mocks binary
/// messengers.
library;

import 'dart:async';
import 'dart:io';

import 'package:ap_discovery_adapter/ap_discovery_adapter.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

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
/// Swift side requests authorization on the first pass, and a closed gate
/// surfaces here as a null pass recorded on [sharedMacApScanGate] (the AP
/// channel reports nothing this cycle, QR/manual entry still work).
Future<List<WlanNetwork>?> Function()? defaultMacApScanner() =>
    Platform.isMacOS
        ? () => macWlanScanOnce(gate: sharedMacApScanGate)
        : null;

/// One scan pass over CoreWLAN. Null when the radio/interface is missing
/// or the location gate is closed — either way this poll cycle has no AP
/// channel verdict. A [gate] receives what blocked the pass (null once a
/// pass gets through) so the environment report can follow the gate.
Future<List<WlanNetwork>?> macWlanScanOnce({
  MacWlanRunner? runner,
  MacApScanGate? gate,
}) async {
  final call = runner ?? _defaultRunner;
  final Object? rows;
  try {
    rows = await call('scan', null);
  } on PlatformException catch (e) {
    final blocker = switch (e.code) {
      'no_interface' => MacApScanBlocker.noInterface,
      'location_denied' => MacApScanBlocker.locationDenied,
      'location_pending' => MacApScanBlocker.locationPending,
      // Not a capability verdict: leave a trace for debug runs and let the
      // poll loop swallow it like any other failed pass.
      _ => null,
    };
    if (blocker == null) {
      debugPrint('mac AP scan failed: ${e.code} ${e.message ?? ''}');
      rethrow;
    }
    gate?.record(blocker);
    return null;
  }
  if (rows == null) return null;
  gate?.record(null);
  return [
    for (final row in (rows as List<Object?>).cast<Map<Object?, Object?>>())
      WlanNetwork(
        ssid: row['ssid'] as String? ?? '',
        signalQuality: _dbmToSignalQuality(row['rssi'] as int? ?? -100),
        profileName: '',
      ),
  ];
}

/// Wi-Fi adapter state as CoreWLAN sees it: `present` says whether a WLAN
/// interface exists at all, `powerOn` whether its radio is on (meaningful
/// only when present).
typedef MacWlanAdapterState = ({bool present, bool powerOn});

/// Reads the Wi-Fi adapter state over the channel (`adapterState`). Null
/// when the native side is unavailable or the answer is malformed — the
/// self-check then reports the AP channel as probe-failed instead of
/// guessing. Unlike [macWlanScanOnce] this needs no Location Services.
Future<MacWlanAdapterState?> macWlanAdapterState({
  MacWlanRunner? runner,
}) async {
  final call = runner ?? _defaultRunner;
  final Object? raw;
  try {
    raw = await call('adapterState', null);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
  if (raw is! Map) return null;
  final present = raw['present'];
  final powerOn = raw['powerOn'];
  if (present is! bool || powerOn is! bool) return null;
  return (present: present, powerOn: powerOn);
}

/// Location Services verdict for the macOS AP channel. CoreWLAN exposes
/// SSIDs only to authorized apps, so the verdict is part of the channel's
/// readiness (names travel over the channel as-is).
enum MacLocationStatus {
  authorized,

  /// Refused, restricted, or Location Services switched off system-wide.
  denied,

  /// Not decided yet; the prompt was already requested this launch.
  pending,

  /// Not decided yet; the first scan pass requests it.
  notRequested,
}

/// Reads the Location Services verdict (`locationStatus`). Null when the
/// native side is unavailable or the answer is unknown — the self-check
/// then keeps the adapter-only AP verdict instead of guessing. Unlike
/// [macWlanScanOnce] this never prompts.
Future<MacLocationStatus?> macWlanLocationStatus({
  MacWlanRunner? runner,
}) async {
  final call = runner ?? _defaultRunner;
  final Object? raw;
  try {
    raw = await call('locationStatus', null);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
  for (final status in MacLocationStatus.values) {
    if (status.name == raw) return status;
  }
  return null;
}

/// What kept the latest macOS AP scan pass from seeing any network.
enum MacApScanBlocker { noInterface, locationDenied, locationPending }

/// Latest AP scan blocker, as reported by the production scanner. The
/// controller's sweep tick reads [blocker] and refreshes the environment
/// report when it changes — level-triggered, so a change landing while a
/// refresh is in flight is still picked up by the next tick.
final class MacApScanGate {
  MacApScanBlocker? _blocker;

  /// The blocker of the latest quiet pass; null once a pass got through.
  MacApScanBlocker? get blocker => _blocker;

  /// Records the outcome of a scan pass.
  void record(MacApScanBlocker? blocker) {
    if (blocker == _blocker) return;
    debugPrint('mac AP scan blocker: ${blocker?.name ?? 'none'}');
    _blocker = blocker;
  }
}

/// The gate behind [defaultMacApScanner].
final MacApScanGate sharedMacApScanGate = MacApScanGate();

/// Production blocker read for the controller's sweep tick: the shared
/// gate on macOS, a constant "nothing blocked" everywhere else.
MacApScanBlocker? Function() defaultMacApBlocker() =>
    Platform.isMacOS ? () => sharedMacApScanGate.blocker : () => null;

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

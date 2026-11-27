/// 桌面端环境探测（M2-3 起，M5 升级 CT-Disc 腿）：BLE 射频 + WLAN 网卡
/// （AP 通道）+ IPv4 网卡枚举（CT-Disc 通道），汇总为
/// [EnvironmentCheckReport]。
///
/// 网卡枚举在 Windows 上用 PowerShell Get-NetAdapter（对象输出，随系统
/// 语言无关；netsh 文本输出会随 locale 变化，不采用），在 macOS 上读
/// CoreWLAN 的无线网卡电源状态；CT-Disc 腿走 dart:io 的网卡枚举
/// （跨平台、无需 PowerShell）。探测失败按该通道 unavailable 处理并
/// 携带原因，不阻塞其余通道。
library;

import 'dart:convert';
import 'dart:io';

import 'package:ble_universal/ble_universal.dart';
import 'package:ct_disc_adapter/ct_disc_adapter.dart';

import 'mac_wlan.dart';

/// 无线网卡在 Get-NetAdapter 里的 PhysicalMediaType 取值。
const String kWlanMediaType = 'Native 802.11';

/// AP channel limited because every WLAN adapter is disabled — the one
/// degraded state the scan page can offer to fix by opening the system
/// Wi-Fi settings page.
const String kWlanDisabledReason = 'wlan_disabled';

/// AP channel limited because macOS Location Services authorization is
/// missing: CoreWLAN hides every SSID without it, and only the first-scan
/// prompt or System Settings can change that.
const String kLocationDeniedReason = 'location_denied';

/// AP channel limited because the Location Services prompt is still
/// unanswered.
const String kLocationPendingReason = 'location_pending';

/// 网卡枚举命令（ConvertTo-Json 单网卡时输出对象而非数组，解析层兼容）。
const String kAdapterQuery =
    'Get-NetAdapter -Physical | Select-Object Name,Status,PhysicalMediaType'
    ' | ConvertTo-Json -Compress';

/// 一块物理网卡的探测快照。
final class NetAdapterInfo {
  const NetAdapterInfo({
    required this.name,
    required this.status,
    required this.mediaType,
  });

  final String name;

  /// Get-NetAdapter 的 Status：Up / Disconnected / Disabled 等。
  final String status;

  /// PhysicalMediaType：'Native 802.11' 为 WLAN，'802.3' 为以太网。
  final String mediaType;
}

/// 解析 kAdapterQuery 的 JSON 输出；不可解析返回 null。
List<NetAdapterInfo>? parseNetAdapters(String jsonText) {
  Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException {
    return null;
  }
  final entries = decoded is List ? decoded : [decoded];
  if (entries.any((entry) => entry is! Map)) return null;
  return [
    for (final entry in entries.cast<Map>())
      NetAdapterInfo(
        name: (entry['Name'] ?? '') as String,
        status: (entry['Status'] ?? '') as String,
        mediaType: (entry['PhysicalMediaType'] ?? '') as String,
      ),
  ];
}

/// WLAN 网卡列表 → AP 通道结论：有已启用的无线网卡即可用（未连接也
/// 能扫描热点）；网卡全被禁用为受限（可修复）；无无线网卡或探测失败
/// 为不可用（UI 呈现为能力限制，而不是空列表）。
ChannelReadiness apChannelReadiness(List<NetAdapterInfo>? adapters) {
  if (adapters == null) {
    return const ChannelReadiness(
      channel: DiscoveryChannel.accessPoint,
      capability: ChannelCapability.unavailable,
      reason: 'adapter_probe_failed',
    );
  }
  final wlan = adapters
      .where((adapter) => adapter.mediaType == kWlanMediaType)
      .toList();
  if (wlan.isEmpty) {
    return const ChannelReadiness(
      channel: DiscoveryChannel.accessPoint,
      capability: ChannelCapability.unavailable,
      reason: 'no_wlan_adapter',
    );
  }
  final enabled = wlan.where((adapter) => adapter.status != 'Disabled');
  if (enabled.isEmpty) {
    return const ChannelReadiness(
      channel: DiscoveryChannel.accessPoint,
      capability: ChannelCapability.limited,
      reason: kWlanDisabledReason,
    );
  }
  return const ChannelReadiness(
    channel: DiscoveryChannel.accessPoint,
    capability: ChannelCapability.available,
    reason: 'ready',
  );
}

/// CoreWLAN 网卡状态 → [apChannelReadiness] 认的网卡列表：无无线网卡为
/// 空列表；电源关闭为一块 Disabled 的无线网卡（判为受限，扫描页随之
/// 提供"打开 Wi-Fi 设置"）；电源开启为就绪。状态未知（通道不可用）
/// 保持 null，结论是探测失败而不是猜测。
List<NetAdapterInfo>? apAdaptersFromMacState(MacWlanAdapterState? state) {
  if (state == null) return null;
  if (!state.present) return const [];
  return [
    NetAdapterInfo(
      name: 'Wi-Fi',
      status: state.powerOn ? 'Up' : 'Disabled',
      mediaType: kWlanMediaType,
    ),
  ];
}

/// Location verdict reader for the production assembly: macOS reads the
/// CoreLocation gate through the mac_wlan channel, other hosts have none.
Future<MacLocationStatus?> locationStatusForHost() async =>
    Platform.isMacOS ? macWlanLocationStatus() : null;

/// Applies the macOS location gate to an adapter-only AP verdict
/// ([apChannelReadiness]). An adapter problem outranks the gate: nothing
/// is gained by blaming location while the radio is missing or off. A
/// closed gate turns a ready channel `limited` (user-fixable; BLE and
/// CT-Disc keep working); authorized, not-yet-requested and unknown (other
/// hosts, probe failure) keep the base verdict.
ChannelReadiness apReadinessWithLocation(
  ChannelReadiness base,
  MacLocationStatus? location,
) {
  if (base.capability != ChannelCapability.available) return base;
  return switch (location) {
    MacLocationStatus.denied => const ChannelReadiness(
        channel: DiscoveryChannel.accessPoint,
        capability: ChannelCapability.limited,
        reason: kLocationDeniedReason,
      ),
    MacLocationStatus.pending => const ChannelReadiness(
        channel: DiscoveryChannel.accessPoint,
        capability: ChannelCapability.limited,
        reason: kLocationPendingReason,
      ),
    MacLocationStatus.authorized ||
    MacLocationStatus.notRequested ||
    null =>
      base,
  };
}

/// CT-Disc 通道结论（M5：从预留常量升级为真实网卡枚举）：有物理网卡
/// 即可用（加入组播监听）；只有 VPN/虚拟网卡为受限（NIC 选择器可显式
/// 勾选）；枚举失败或无任何 IPv4 端点为不可用。
ChannelReadiness ctDiscChannelReadiness(List<NicEndpoint>? endpoints) {
  if (endpoints == null) {
    return const ChannelReadiness(
      channel: DiscoveryChannel.ctDisc,
      capability: ChannelCapability.unavailable,
      reason: 'nic_probe_failed',
    );
  }
  if (endpoints.isEmpty) {
    return const ChannelReadiness(
      channel: DiscoveryChannel.ctDisc,
      capability: ChannelCapability.unavailable,
      reason: 'no_nic',
    );
  }
  final physical = endpoints.where(
    (endpoint) => endpoint.nicClass == NicClass.physical,
  );
  if (physical.isEmpty) {
    return const ChannelReadiness(
      channel: DiscoveryChannel.ctDisc,
      capability: ChannelCapability.limited,
      reason: 'only_virtual_nics',
    );
  }
  return const ChannelReadiness(
    channel: DiscoveryChannel.ctDisc,
    capability: ChannelCapability.available,
    reason: 'ready',
  );
}

/// 桌面端环境探测：BLE 与网卡枚举并行执行，失败互不牵连。
class DesktopEnvironmentProbe {
  DesktopEnvironmentProbe({
    Future<CtEnvironmentReport> Function()? probeBle,
    Future<String?> Function()? enumerateAdapters,
    Future<MacLocationStatus?> Function()? locationStatus,
    Future<List<NicEndpoint>> Function({bool includeVirtual})? nicEnumerator,
    this.legTimeout = const Duration(seconds: 10),
  }) : _probeBle = probeBle ?? UniversalCtEnvironment.probe,
       // 注入的 enumerateAdapters 保留 JSON 字符串契约（测试夹具沿用），
       // 包装成网卡列表；默认来源按宿主分派。
       _enumerateAdapters = enumerateAdapters == null
           ? _adaptersForHost
           : _adaptersFromJson(enumerateAdapters),
       // No host default for the location leg: widget tests inject the
       // other legs, and on a macOS host a real channel call never settles
       // in their fake clock. The production assembly passes
       // [locationStatusForHost].
       _locationStatus = locationStatus ?? _noLocationStatus,
       _nicEnumerator = nicEnumerator ?? enumerateNicEndpoints;

  final Future<CtEnvironmentReport> Function() _probeBle;
  final Future<List<NetAdapterInfo>?> Function() _enumerateAdapters;
  final Future<MacLocationStatus?> Function() _locationStatus;
  final Future<List<NicEndpoint>> Function({bool includeVirtual})
  _nicEnumerator;

  /// Per-leg cap. A hung WinRT radio query (or a stuck PowerShell child)
  /// must resolve as a degraded report instead of wedging the caller —
  /// round-3 A2 found a wedged probe turns the re-check button permanently
  /// silent (the controller guards re-entry with an in-flight flag).
  final Duration legTimeout;

  /// 一次完整探测。BLE 探测异常按 transient 降级（携带原因）。
  Future<EnvironmentCheckReport> probe() async {
    // 用 try/catch 而不是 Future.catchError：抛错的 async 闭包实际类型
    // 参数是 Never，catchError 的运行时类型检查会拒绝处理器返回值。
    final results = await Future.wait([
      _guardedBleProbe().timeout(legTimeout, onTimeout: _bleTimedOut),
      _guardedAdapters().timeout(legTimeout, onTimeout: () => null),
      _guardedNics().timeout(legTimeout, onTimeout: () => null),
      _guardedLocation().timeout(legTimeout, onTimeout: () => null),
    ]);
    final bleReport = results[0] as CtEnvironmentReport;
    final adapters = results[1] as List<NetAdapterInfo>?;
    final nics = results[2] as List<NicEndpoint>?;
    final location = results[3] as MacLocationStatus?;
    return EnvironmentCheckReport(
      channels: [
        bleChannelReadiness(bleReport),
        apReadinessWithLocation(apChannelReadiness(adapters), location),
        ctDiscChannelReadiness(nics),
      ],
    );
  }

  static CtEnvironmentReport _bleTimedOut() => const CtEnvironmentReport(
    readiness: CtBleReadiness.transient,
    detail: 'probe timed out',
  );

  Future<CtEnvironmentReport> _guardedBleProbe() async {
    try {
      return await _probeBle();
    } catch (error) {
      return CtEnvironmentReport(
        readiness: CtBleReadiness.transient,
        detail: 'probe failed: $error',
      );
    }
  }

  Future<List<NetAdapterInfo>?> _guardedAdapters() async {
    try {
      return await _enumerateAdapters();
    } catch (_) {
      return null;
    }
  }

  Future<List<NicEndpoint>?> _guardedNics() async {
    try {
      return await _nicEnumerator(includeVirtual: true);
    } catch (_) {
      return null;
    }
  }

  /// 把注入的 JSON 字符串枚举器包装成网卡列表来源（测试夹具的契约
  /// 保持不变）。块体闭包不能写在构造初始化列表里，所以经由本方法返回。
  static Future<List<NetAdapterInfo>?> Function() _adaptersFromJson(
    Future<String?> Function() enumerateAdapters,
  ) {
    return () async {
      final jsonText = await enumerateAdapters();
      return jsonText == null ? null : parseNetAdapters(jsonText);
    };
  }

  /// Bare catch on purpose: a macOS test host may throw something that is
  /// neither a PlatformException nor a MissingPluginException.
  Future<MacLocationStatus?> _guardedLocation() async {
    try {
      return await _locationStatus();
    } catch (_) {
      return null;
    }
  }

  static Future<MacLocationStatus?> _noLocationStatus() async => null;

  /// 默认网卡来源，按宿主分派：Windows 走 PowerShell，macOS 读 CoreWLAN
  /// 电源状态，其余宿主不提供网卡信息（结论降级为探测失败）。
  static Future<List<NetAdapterInfo>?> _adaptersForHost() async {
    if (Platform.isWindows) {
      final jsonText = await _queryAdaptersViaPowerShell();
      return jsonText == null ? null : parseNetAdapters(jsonText);
    }
    if (Platform.isMacOS) {
      return apAdaptersFromMacState(await macWlanAdapterState());
    }
    return null;
  }

  static Future<String?> _queryAdaptersViaPowerShell() async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      kAdapterQuery,
    ]);
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  }
}

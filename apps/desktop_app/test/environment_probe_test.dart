import 'dart:async';
import 'dart:io';

import 'package:ble_universal/ble_universal.dart';
import 'package:ct_disc_adapter/ct_disc_adapter.dart';
import 'package:desktop_app/services/environment_probe.dart';
import 'package:desktop_app/services/mac_wlan.dart'
    show MacLocationStatus;
import 'package:flutter_test/flutter_test.dart';

// 一块物理网卡的可枚举替身（CT-Disc 腿确定性可用）。
Future<List<NicEndpoint>> nicList({bool includeVirtual = false}) async => [
      NicEndpoint(
        interfaceName: 'Ethernet',
        address: InternetAddress('192.168.93.20'),
        nicClass: NicClass.physical,
      ),
    ];

void main() {
  group('parseNetAdapters', () {
    test('多网卡数组输出', () {
      const jsonText =
          '[{"Name":"Wi-Fi","Status":"Up","PhysicalMediaType":"Native 802.11"},'
          '{"Name":"以太网","Status":"Disconnected","PhysicalMediaType":"802.3"}]';
      final adapters = parseNetAdapters(jsonText);

      expect(adapters, hasLength(2));
      expect(adapters![0].name, 'Wi-Fi');
      expect(adapters[0].status, 'Up');
      expect(adapters[0].mediaType, 'Native 802.11');
      expect(adapters[1].mediaType, '802.3');
    });

    test('单网卡时 ConvertTo-Json 输出对象而非数组', () {
      const jsonText =
          '{"Name":"Wi-Fi","Status":"Disabled","PhysicalMediaType":"Native 802.11"}';
      final adapters = parseNetAdapters(jsonText);

      expect(adapters, hasLength(1));
      expect(adapters!.single.status, 'Disabled');
    });

    test('不可解析输出返回 null', () {
      expect(parseNetAdapters('not json'), isNull);
    });
  });

  group('apChannelReadiness', () {
    NetAdapterInfo adapter({
      String mediaType = 'Native 802.11',
      String status = 'Up',
    }) => NetAdapterInfo(name: 'Wi-Fi', status: status, mediaType: mediaType);

    test('有已启用的无线网卡 → available', () {
      final entry = apChannelReadiness([
        adapter(mediaType: '802.3'),
        adapter(status: 'Disconnected'),
      ]);
      expect(entry.capability, ChannelCapability.available);
      expect(entry.reason, 'ready');
    });

    test('无线网卡全被禁用 → limited（可修复）', () {
      final entry = apChannelReadiness([adapter(status: 'Disabled')]);
      expect(entry.capability, ChannelCapability.limited);
      expect(entry.reason, 'wlan_disabled');
    });

    test('无无线网卡 → unavailable（呈现为能力限制）', () {
      final entry = apChannelReadiness([
        adapter(mediaType: '802.3', status: 'Up'),
      ]);
      expect(entry.capability, ChannelCapability.unavailable);
      expect(entry.reason, 'no_wlan_adapter');
    });

    test('探测失败（null）→ unavailable', () {
      final entry = apChannelReadiness(null);
      expect(entry.capability, ChannelCapability.unavailable);
      expect(entry.reason, 'adapter_probe_failed');
    });
  });

  group('DesktopEnvironmentProbe.probe', () {
    test('BLE 就绪 + 有无线网卡 → 可继续，三通道齐备', () async {
      final probe = DesktopEnvironmentProbe(
        probeBle: () async => const CtEnvironmentReport(
          readiness: CtBleReadiness.ready,
          detail: 'radio on',
        ),
        enumerateAdapters: () async => '[{"Name":"Wi-Fi","Status":"Up","PhysicalMediaType":"Native 802.11"}]',
        nicEnumerator: nicList,
      );

      final report = await probe.probe();

      expect(report.canProceed, isTrue);
      expect(
        report.channel(DiscoveryChannel.ble)?.capability,
        ChannelCapability.available,
      );
      expect(
        report.channel(DiscoveryChannel.accessPoint)?.capability,
        ChannelCapability.available,
      );
      // M5 起 CT-Disc 是真实网卡枚举腿：物理网卡在场即可用。
      expect(
        report.channel(DiscoveryChannel.ctDisc)?.capability,
        ChannelCapability.available,
      );
    });

    test('AP 枚举受限但 BLE 可用仍可继续（验收：受限不是空列表）', () async {
      final probe = DesktopEnvironmentProbe(
        probeBle: () async => const CtEnvironmentReport(
          readiness: CtBleReadiness.ready,
          detail: 'radio on',
        ),
        enumerateAdapters: () async => null,
        nicEnumerator: nicList,
      );

      final report = await probe.probe();

      expect(report.canProceed, isTrue);
      final ap = report.channel(DiscoveryChannel.accessPoint)!;
      expect(ap.capability, ChannelCapability.unavailable);
      expect(ap.reason, 'adapter_probe_failed');
    });

    test('BLE 探测抛异常按 transient 降级，不牵连其余通道', () async {
      final probe = DesktopEnvironmentProbe(
        probeBle: () async => throw Exception('radio gone'),
        enumerateAdapters: () async => '[{"Name":"Wi-Fi","Status":"Up","PhysicalMediaType":"Native 802.11"}]',
        nicEnumerator: nicList,
      );

      final report = await probe.probe();

      final ble = report.channel(DiscoveryChannel.ble)!;
      expect(ble.capability, ChannelCapability.limited);
      expect(ble.reason, 'transient');
      expect(ble.detail, contains('radio gone'));
      expect(
        report.channel(DiscoveryChannel.accessPoint)?.capability,
        ChannelCapability.available,
      );
    });

    test('全部通道不可用 → 不可继续', () async {
      final probe = DesktopEnvironmentProbe(
        probeBle: () async => const CtEnvironmentReport(
          readiness: CtBleReadiness.poweredOff,
          detail: 'radio off',
        ),
        enumerateAdapters: () async => null,
        nicEnumerator: ({bool includeVirtual = false}) async => [],
      );

      final report = await probe.probe();

      expect(report.canProceed, isFalse);
    });

    // Round-3 A2: a wedged probe leg must resolve via the cap, not hang the
    // caller (the controller's in-flight flag would brick the re-check
    // button).
    test('a hung leg resolves as a degraded report after the cap', () async {
      final probe = DesktopEnvironmentProbe(
        probeBle: () => Completer<CtEnvironmentReport>().future,
        enumerateAdapters: () => Completer<String?>().future,
        nicEnumerator: ({bool includeVirtual = false}) =>
            Completer<List<NicEndpoint>>().future,
        legTimeout: const Duration(milliseconds: 50),
      );

      final report = await probe.probe();

      final ble = report.channel(DiscoveryChannel.ble)!;
      expect(ble.capability, ChannelCapability.limited);
      expect(ble.reason, 'transient');
      expect(ble.detail, contains('timed out'));
      expect(
        report.channel(DiscoveryChannel.accessPoint)?.reason,
        'adapter_probe_failed',
      );
    });

    test('unparseable adapter JSON degrades to adapter_probe_failed',
        () async {
      final probe = DesktopEnvironmentProbe(
        probeBle: () async => const CtEnvironmentReport(
          readiness: CtBleReadiness.ready,
          detail: 'radio on',
        ),
        enumerateAdapters: () async => 'not json',
        nicEnumerator: nicList,
      );

      final report = await probe.probe();

      expect(
        report.channel(DiscoveryChannel.accessPoint)?.reason,
        'adapter_probe_failed',
      );
    });
  });

  // macOS leg of the adapter enumeration: CoreWLAN reports one WLAN
  // interface's power state instead of a Get-NetAdapter table, so it is
  // mapped onto the adapter list apChannelReadiness already understands.
  group('apAdaptersFromMacState', () {
    test('unknown state stays null (probe failed)', () {
      expect(apAdaptersFromMacState(null), isNull);
    });

    test('no WLAN interface is an empty list (no_wlan_adapter)', () {
      final adapters =
          apAdaptersFromMacState((present: false, powerOn: false));
      expect(adapters, isEmpty);
      expect(apChannelReadiness(adapters).reason, 'no_wlan_adapter');
    });

    test('powered off maps to a disabled adapter (wlan_disabled)', () {
      final readiness = apChannelReadiness(
        apAdaptersFromMacState((present: true, powerOn: false)),
      );
      expect(readiness.capability, ChannelCapability.limited);
      expect(readiness.reason, kWlanDisabledReason);
    });

    test('powered on maps to an enabled adapter (ready)', () {
      final adapters =
          apAdaptersFromMacState((present: true, powerOn: true))!;
      expect(adapters.single.mediaType, kWlanMediaType);
      final readiness = apChannelReadiness(adapters);
      expect(readiness.capability, ChannelCapability.available);
      expect(readiness.reason, 'ready');
    });
  });

  // macOS location gate: CoreWLAN hides SSIDs unless the app is authorized
  // for Location Services, so the AP verdict composes the adapter state
  // with the location status.
  group('apReadinessWithLocation', () {
    const ready = ChannelReadiness(
      channel: DiscoveryChannel.accessPoint,
      capability: ChannelCapability.available,
      reason: 'ready',
    );

    test('a closed location gate limits an otherwise ready channel', () {
      final denied = apReadinessWithLocation(ready, MacLocationStatus.denied);
      expect(denied.capability, ChannelCapability.limited);
      expect(denied.reason, kLocationDeniedReason);

      final pending = apReadinessWithLocation(ready, MacLocationStatus.pending);
      expect(pending.capability, ChannelCapability.limited);
      expect(pending.reason, kLocationPendingReason);
    });

    test('authorized, not yet requested, and unknown keep the base', () {
      for (final location in [
        MacLocationStatus.authorized,
        MacLocationStatus.notRequested,
        null,
      ]) {
        expect(apReadinessWithLocation(ready, location), same(ready),
            reason: '$location');
      }
    });

    test('an adapter problem outranks the location verdict', () {
      const disabled = ChannelReadiness(
        channel: DiscoveryChannel.accessPoint,
        capability: ChannelCapability.limited,
        reason: kWlanDisabledReason,
      );
      expect(
        apReadinessWithLocation(disabled, MacLocationStatus.denied),
        same(disabled),
      );
    });
  });

  group('DesktopEnvironmentProbe location leg', () {
    DesktopEnvironmentProbe probeWith(
      Future<MacLocationStatus?> Function() locationStatus, {
      Duration legTimeout = const Duration(seconds: 10),
    }) =>
        DesktopEnvironmentProbe(
          probeBle: () async => const CtEnvironmentReport(
            readiness: CtBleReadiness.ready,
            detail: 'fake ready',
          ),
          enumerateAdapters: () async =>
              '[{"Name":"Wi-Fi","Status":"Up",'
              '"PhysicalMediaType":"Native 802.11"}]',
          locationStatus: locationStatus,
          nicEnumerator: ({bool includeVirtual = false}) async => [],
          legTimeout: legTimeout,
        );

    test('a denied location status limits the AP entry; flow proceeds',
        () async {
      final report =
          await probeWith(() async => MacLocationStatus.denied).probe();

      final ap = report.channel(DiscoveryChannel.accessPoint)!;
      expect(ap.capability, ChannelCapability.limited);
      expect(ap.reason, kLocationDeniedReason);
      expect(report.canProceed, isTrue);
    });

    test('a hung location leg resolves as no verdict after the cap', () async {
      final report = await probeWith(
        () => Completer<MacLocationStatus?>().future,
        legTimeout: const Duration(milliseconds: 50),
      ).probe();

      final ap = report.channel(DiscoveryChannel.accessPoint)!;
      expect(ap.capability, ChannelCapability.available);
      expect(ap.reason, 'ready');
    });
  });
}

import 'dart:async';

import 'package:discovery_domain/discovery_domain.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime(2026, 11, 3, 12, 0, 0);

  DiscoveryCandidate bleCandidate(
    String? macSuffix, {
    String candidateId = 'dev-1',
    DateTime? lastSeen,
    bool busy = false,
    bool provisionable = true,
    int? signal = -55,
    String? modelHint = 'NE101',
    String? host,
  }) =>
      DiscoveryCandidate(
        candidateId: candidateId,
        macSuffix: macSuffix,
        modelHint: modelHint,
        host: host,
        channels: const {DiscoveryChannel.ble},
        provisionable: provisionable,
        busy: busy,
        lastSeen: lastSeen ?? t0,
        signal: signal,
      );

  test('发现通道枚举为三路', () {
    expect(DiscoveryChannel.values.length, 3);
  });

  group('DiscoveryRegistry 跨通道合并', () {
    test('同 macSuffix 两条记录合并为一条，取较晚时间与最近信号', () {
      final registry = DiscoveryRegistry();
      registry.absorb(bleCandidate('A1B2C3', signal: -55));
      registry.absorb(
        bleCandidate(
          'a1b2c3',
          lastSeen: t0.add(const Duration(seconds: 3)),
          signal: -70,
        ),
      );

      expect(registry.snapshot, hasLength(1));
      final merged = registry.snapshot.single;
      expect(merged.lastSeen, t0.add(const Duration(seconds: 3)));
      expect(merged.signal, -70);
      expect(merged.candidateId, 'dev-1');
    });

    test('不同 macSuffix 保持独立条目', () {
      final registry = DiscoveryRegistry();
      registry.absorb(bleCandidate('A1B2C3', candidateId: 'dev-1'));
      registry.absorb(bleCandidate('84C102', candidateId: 'dev-2'));

      expect(registry.snapshot, hasLength(2));
      expect(registry.snapshot.map((c) => c.macSuffix).toSet(), {
        'A1B2C3',
        '84C102',
      });
    });

    test('macSuffix 缺失时按 candidateId 独立成条', () {
      final registry = DiscoveryRegistry();
      registry.absorb(bleCandidate(null, candidateId: 'dev-1'));
      registry.absorb(bleCandidate(null, candidateId: 'dev-2'));

      expect(registry.snapshot, hasLength(2));
    });

    test('最近记录忙时强制不可配置（§4.2.2）', () {
      final registry = DiscoveryRegistry();
      registry.absorb(bleCandidate('A1B2C3', provisionable: true));
      registry.absorb(
        bleCandidate(
          'A1B2C3',
          lastSeen: t0.add(const Duration(seconds: 1)),
          busy: true,
          provisionable: false,
        ),
      );

      final merged = registry.snapshot.single;
      expect(merged.busy, isTrue);
      expect(merged.provisionable, isFalse);
    });

    test('modelHint 与 signal 取首见/最近非空值', () {
      final registry = DiscoveryRegistry();
      registry.absorb(bleCandidate('A1B2C3', modelHint: 'NE101', signal: -50));
      registry.absorb(
        bleCandidate(
          'A1B2C3',
          lastSeen: t0.add(const Duration(seconds: 1)),
          modelHint: null,
          signal: null,
        ),
      );

      final merged = registry.snapshot.single;
      expect(merged.modelHint, 'NE101');
      expect(merged.signal, -50);
    });

    test('host 取最近非空值（DHCP 变更跟新值，缺失保留旧值）', () {
      final registry = DiscoveryRegistry();
      registry.absorb(bleCandidate('A1B2C3', host: '192.168.93.72'));
      registry.absorb(
        bleCandidate(
          'A1B2C3',
          lastSeen: t0.add(const Duration(seconds: 5)),
          host: '192.168.93.99',
        ),
      );
      expect(registry.snapshot.single.host, '192.168.93.99');

      // 无线通道记录（host=null）并入时不得清掉已有 LAN 地址。
      registry.absorb(
        bleCandidate(
          'A1B2C3',
          candidateId: 'dev-ble',
          lastSeen: t0.add(const Duration(seconds: 8)),
          host: null,
        ),
      );
      expect(registry.snapshot.single.host, '192.168.93.99');
    });

    test('updates 流发出每次合并后的候选', () async {
      final registry = DiscoveryRegistry();
      // 先订阅再驱动：广播流事件异步投递，事后 listen 会漏事件。
      final emittedFuture = registry.updates.take(2).toList();
      registry.absorb(bleCandidate('A1B2C3'));
      registry.absorb(
        bleCandidate('A1B2C3', lastSeen: t0.add(const Duration(seconds: 2))),
      );
      final emitted = await emittedFuture;

      expect(emitted, hasLength(2));
      expect(emitted.last.lastSeen, t0.add(const Duration(seconds: 2)));
    });
  });

  group('DiscoveryRegistry 超时淘汰', () {
    test('只淘汰超过 ttl 的候选并返回被移除项', () {
      final registry = DiscoveryRegistry();
      registry.absorb(bleCandidate('A1B2C3', lastSeen: t0));
      registry.absorb(
        bleCandidate('84C102', lastSeen: t0.add(const Duration(seconds: 20))),
      );

      final removed = registry.sweepExpired(
        t0.add(const Duration(seconds: 30)),
        ttl: const Duration(seconds: 25),
      );

      expect(removed.map((c) => c.macSuffix), ['A1B2C3']);
      expect(registry.snapshot, hasLength(1));
      expect(registry.snapshot.single.macSuffix, '84C102');
    });

    test('重新出现的候选不被淘汰', () {
      final registry = DiscoveryRegistry();
      registry.absorb(
        bleCandidate('A1B2C3', lastSeen: t0.add(const Duration(seconds: 40))),
      );

      final removed = registry.sweepExpired(
        t0.add(const Duration(seconds: 50)),
      );
      expect(removed, isEmpty);
      expect(registry.snapshot, hasLength(1));
    });
  });

  group('per-channel TTL sweep (CT-Disc v1.2.0 §5)', () {
    DiscoveryCandidate candidate(
      Set<DiscoveryChannel> channels, {
      Map<DiscoveryChannel, DateTime>? lastSeenByChannel,
      DateTime? lastSeen,
    }) =>
        DiscoveryCandidate(
          candidateId: 'dev-1',
          macSuffix: 'A1B2C3',
          channels: channels,
          provisionable: true,
          busy: false,
          lastSeen: lastSeen ?? t0,
          lastSeenByChannel: lastSeenByChannel ?? const {},
        );

    test('merged row survives while any channel leg is within its own TTL',
        () {
      final registry = DiscoveryRegistry();
      // Both legs seen at t0. BLE TTL 12 s, CT-Disc TTL 30 s.
      registry.absorb(candidate(
        const {DiscoveryChannel.ble},
        lastSeenByChannel: {DiscoveryChannel.ble: t0},
      ));
      registry.absorb(candidate(
        const {DiscoveryChannel.ctDisc},
        lastSeenByChannel: {DiscoveryChannel.ctDisc: t0},
      ));

      // At t0+20s the BLE leg expired but CT-Disc is still fresh: the
      // row must stay (a global 12 s sweep would have dropped it).
      final removed = registry.sweepExpired(
        t0.add(const Duration(seconds: 20)),
        ttlByChannel: const {
          DiscoveryChannel.ctDisc: Duration(seconds: 30),
        },
      );

      expect(removed, isEmpty);
      expect(registry.snapshot, hasLength(1));
      // The merge keeps per-channel liveness, not just the overall max.
      expect(
        registry.snapshot.single.lastSeenByChannel.keys,
        const {DiscoveryChannel.ble, DiscoveryChannel.ctDisc},
      );
    });

    test('row expires only after every channel leg is past its TTL', () {
      final registry = DiscoveryRegistry();
      registry.absorb(candidate(
        const {DiscoveryChannel.ctDisc},
        lastSeenByChannel: {DiscoveryChannel.ctDisc: t0},
      ));

      final removed = registry.sweepExpired(
        t0.add(const Duration(seconds: 31)),
        ttlByChannel: const {
          DiscoveryChannel.ctDisc: Duration(seconds: 30),
        },
      );

      expect(removed.map((c) => c.macSuffix), ['A1B2C3']);
      expect(registry.snapshot, isEmpty);
    });

    test('merge takes the newer timestamp per channel', () {
      final registry = DiscoveryRegistry();
      registry.absorb(candidate(
        const {DiscoveryChannel.ctDisc},
        lastSeenByChannel: {DiscoveryChannel.ctDisc: t0},
      ));
      registry.absorb(candidate(
        const {DiscoveryChannel.ctDisc},
        lastSeenByChannel: {
          DiscoveryChannel.ctDisc: t0.add(const Duration(seconds: 5)),
        },
      ));

      expect(
        registry.snapshot.single.lastSeenByChannel[DiscoveryChannel.ctDisc],
        t0.add(const Duration(seconds: 5)),
      );
    });

    test('empty per-channel map keeps the legacy single-TTL behavior', () {
      final registry = DiscoveryRegistry();
      // Old sources (BLE/AP) build candidates without the map; a channel
      // override must not leak onto them — they keep expiring on the
      // default ttl against the overall lastSeen.
      registry.absorb(bleCandidate('A1B2C3', lastSeen: t0));

      final removed = registry.sweepExpired(
        t0.add(const Duration(seconds: 20)),
        ttlByChannel: const {
          DiscoveryChannel.ctDisc: Duration(seconds: 30),
        },
      );

      expect(removed.map((c) => c.macSuffix), ['A1B2C3']);
      expect(registry.snapshot, isEmpty);
    });
  });

  group('环境自检汇总', () {
    ChannelReadiness readiness(
      DiscoveryChannel channel,
      ChannelCapability capability, {
      String reason = 'ready',
    }) =>
        ChannelReadiness(
          channel: channel,
          capability: capability,
          reason: reason,
        );

    test('至少一条通道可用即可继续（其余仅受限不阻塞）', () {
      final report = EnvironmentCheckReport(
        channels: [
          readiness(DiscoveryChannel.ble, ChannelCapability.available),
          readiness(
            DiscoveryChannel.accessPoint,
            ChannelCapability.limited,
            reason: 'wlan_disabled',
          ),
          readiness(
            DiscoveryChannel.ctDisc,
            ChannelCapability.unavailable,
            reason: 'reserved',
          ),
        ],
      );
      expect(report.canProceed, isTrue);
    });

    test('全部受限或不可用时不可继续', () {
      final report = EnvironmentCheckReport(
        channels: [
          readiness(
            DiscoveryChannel.ble,
            ChannelCapability.unavailable,
            reason: 'powered_off',
          ),
          readiness(
            DiscoveryChannel.accessPoint,
            ChannelCapability.limited,
            reason: 'wlan_disabled',
          ),
        ],
      );
      expect(report.canProceed, isFalse);
    });

    test('按通道取结论，未覆盖返回 null', () {
      final report = EnvironmentCheckReport(
        channels: [
          readiness(DiscoveryChannel.ble, ChannelCapability.available),
        ],
      );
      expect(
        report.channel(DiscoveryChannel.ble)?.capability,
        ChannelCapability.available,
      );
      expect(report.channel(DiscoveryChannel.ctDisc), isNull);
    });
  });

  group('CompositeDiscoverySource', () {
    // Minimal controllable source for the fan-in tests.
    StreamController<DiscoveryCandidate>? emissions;
    int startCalls = 0;
    int stopCalls = 0;
    final fake = _CountingSource.custom(
      onStart: () => startCalls++,
      onStop: () => stopCalls++,
      stream: () => emissions!.stream,
    );

    setUp(() {
      startCalls = 0;
      stopCalls = 0;
      emissions = StreamController<DiscoveryCandidate>.broadcast();
    });

    tearDown(() async {
      await emissions?.close();
      emissions = null;
    });

    test('fans in child streams and propagates start/stop', () async {
      final composite = CompositeDiscoverySource([
        fake,
        _CountingSource.custom(
          stream: () => const Stream<DiscoveryCandidate>.empty(),
        ),
      ]);
      final received = <DiscoveryCandidate>[];
      final sub = composite.candidates.listen(received.add);
      await composite.start();
      expect(startCalls, 1);

      emissions!.add(
        DiscoveryCandidate(
          candidateId: 'ap:CT-AP-BBC6DC',
          macSuffix: 'BBC6DC',
          channels: const {DiscoveryChannel.accessPoint},
          provisionable: true,
          busy: false,
          lastSeen: t0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received.single.macSuffix, 'BBC6DC');

      await composite.stop();
      expect(stopCalls, 1);
      await sub.cancel();
    });

    test('a failing child stream does not stop the healthy ones', () async {
      final broken = StreamController<DiscoveryCandidate>.broadcast();
      final composite = CompositeDiscoverySource([
        _CountingSource.custom(stream: () => broken.stream),
        fake,
      ]);
      final received = <DiscoveryCandidate>[];
      final sub = composite.candidates.listen(received.add);
      await composite.start();

      broken.addError(StateError('wlan stack died'));
      emissions!.add(
        DiscoveryCandidate(
          candidateId: 'ctdisc:84C102@Ethernet',
          macSuffix: '84C102',
          channels: const {DiscoveryChannel.ctDisc},
          provisionable: true,
          busy: false,
          lastSeen: t0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received.single.channels, const {DiscoveryChannel.ctDisc});

      await composite.stop();
      await sub.cancel();
      await broken.close();
    });

    test('start/stop are idempotent through the composite', () async {
      final composite = CompositeDiscoverySource([fake]);
      await composite.start();
      await composite.start();
      expect(startCalls, 1);
      await composite.stop();
      await composite.stop();
      expect(stopCalls, 1);

      // …and the cycle repeats: a start() with nothing left to do must not
      // leave the "start in flight" slot occupied for the next one.
      await composite.start();
      expect(startCalls, 2);
    });

    // One channel's radio must not decide for the others: a machine with
    // no Bluetooth still needs its softAP and CT-Disc channels.

    test('a child that fails to start leaves its siblings running', () async {
      final composite = CompositeDiscoverySource([
        _refusingToStart(DiscoveryChannel.ble, StateError('radio off')),
        fake,
      ]);
      final received = <DiscoveryCandidate>[];
      final sub = composite.candidates.listen(received.add);

      await composite.start();

      expect(startCalls, 1);
      expect(composite.startErrors.keys, [DiscoveryChannel.ble]);
      emissions!.add(bleCandidate('A1B2C3'));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));

      await composite.stop();
      await sub.cancel();
    });

    test('a failing child without a declared channel is not listed', () async {
      final composite = CompositeDiscoverySource([
        _CountingSource.custom(
          onStart: () => throw StateError('boom'),
          stream: _silent,
        ),
        fake,
      ]);

      await composite.start();

      expect(startCalls, 1);
      expect(composite.startErrors, isEmpty);
    });

    test('throws only when every child fails to start', () async {
      final radioOff = StateError('radio off');
      final composite = CompositeDiscoverySource([
        _refusingToStart(DiscoveryChannel.ble, radioOff),
        _refusingToStart(
          DiscoveryChannel.accessPoint,
          StateError('WLAN service unavailable'),
        ),
      ]);

      await expectLater(composite.start(), throwsA(same(radioOff)));
      expect(composite.startErrors.keys, [
        DiscoveryChannel.ble,
        DiscoveryChannel.accessPoint,
      ]);
    });

    test('a failed child is retried; running ones are not restarted', () async {
      Object? radioOff = StateError('radio off');
      var bleAttempts = 0;
      final ble = _ChannelSource(
        channel: DiscoveryChannel.ble,
        onStart: () {
          bleAttempts++;
          final error = radioOff;
          if (error != null) throw error;
        },
        stream: _silent,
      );
      final composite = CompositeDiscoverySource([ble, fake]);

      await composite.start();
      expect(composite.startErrors.keys, [DiscoveryChannel.ble]);

      // Still off: only the failed child is attempted again.
      await composite.start();
      expect(bleAttempts, 2);
      expect(startCalls, 1);

      radioOff = null;
      await composite.start();
      expect(bleAttempts, 3);
      expect(startCalls, 1);
      expect(composite.startErrors, isEmpty);
    });

    test('starts cleanly again after every child failed', () async {
      Object? outage = StateError('radio stack down');
      final composite = CompositeDiscoverySource([
        _ChannelSource(
          channel: DiscoveryChannel.ble,
          onStart: () {
            if (outage != null) throw outage;
          },
          stream: () => emissions!.stream,
        ),
      ]);
      await expectLater(composite.start(), throwsA(isA<StateError>()));

      outage = null;
      await composite.start();
      final received = <DiscoveryCandidate>[];
      final sub = composite.candidates.listen(received.add);
      emissions!.add(bleCandidate('A1B2C3'));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));

      await composite.stop();
      await sub.cancel();
    });

    test('concurrent starts share one attempt per child', () async {
      final radioReady = Completer<void>();
      var attempts = 0;
      final composite = CompositeDiscoverySource([
        _ChannelSource(
          channel: DiscoveryChannel.ble,
          onStart: () {
            attempts++;
            return radioReady.future;
          },
          stream: _silent,
        ),
      ]);

      final first = composite.start();
      final second = composite.start();
      radioReady.complete();
      await first;
      await second;

      expect(attempts, 1);
    });

    test('stop after a partial start stops every child', () async {
      var radioOffStops = 0;
      final composite = CompositeDiscoverySource([
        _ChannelSource(
          channel: DiscoveryChannel.ble,
          onStart: () => throw StateError('radio off'),
          onStop: () => radioOffStops++,
          stream: _silent,
        ),
        fake,
      ]);
      await composite.start();
      expect(composite.startErrors, isNotEmpty);

      await composite.stop();

      expect(radioOffStops, 1);
      expect(stopCalls, 1);
      expect(composite.startErrors, isEmpty);
    });

    test('a child that fails to stop keeps the others stopped', () async {
      final stuck = StateError('scan could not be stopped');
      final composite = CompositeDiscoverySource([
        _ChannelSource(
          channel: DiscoveryChannel.ble,
          onStop: () => throw stuck,
          stream: _silent,
        ),
        fake,
      ]);
      await composite.start();

      await expectLater(composite.stop(), throwsA(same(stuck)));
      expect(stopCalls, 1);

      // The failure left no residue: the next window forwards again.
      await composite.start();
      final received = <DiscoveryCandidate>[];
      final sub = composite.candidates.listen(received.add);
      emissions!.add(bleCandidate('A1B2C3'));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      await sub.cancel();
    });
  });
}

/// Test double implementing the port with injected behavior; the hooks may
/// be async (a start that waits on a radio).
class _CountingSource implements DiscoverySource {
  _CountingSource.custom({
    FutureOr<void> Function()? onStart,
    FutureOr<void> Function()? onStop,
    required Stream<DiscoveryCandidate> Function() stream,
  })  : _onStart = onStart,
        _onStop = onStop,
        _stream = stream;

  final FutureOr<void> Function()? _onStart;
  final FutureOr<void> Function()? _onStop;
  final Stream<DiscoveryCandidate> Function() _stream;

  @override
  Stream<DiscoveryCandidate> get candidates => _stream();

  @override
  Future<void> start() async {
    await _onStart?.call();
  }

  @override
  Future<void> stop() async {
    await _onStop?.call();
  }
}

/// [_CountingSource] bound to one channel, the way the real adapters are.
class _ChannelSource extends _CountingSource implements ChannelDiscoverySource {
  _ChannelSource({
    required this.channel,
    super.onStart,
    super.onStop,
    required super.stream,
  }) : super.custom();

  @override
  final DiscoveryChannel channel;
}

/// A candidate stream that never emits.
Stream<DiscoveryCandidate> _silent() =>
    const Stream<DiscoveryCandidate>.empty();

/// A channel-bound child whose start() always throws [error].
_ChannelSource _refusingToStart(DiscoveryChannel channel, Object error) =>
    _ChannelSource(
      channel: channel,
      onStart: () => throw error,
      stream: _silent,
    );

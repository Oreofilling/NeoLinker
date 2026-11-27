/// universal_ble 的 CtGattChannel 实现：连接、发现、MTU、订阅与读写。
///
/// Windows PoC 在打开本通道前先完成系统 bonding，避免 PairAsync 与服务
/// 发现、CCCD 写入竞争；设备侧安全请求仍作为未配对客户端的兜底。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:ble_adapter/ble_adapter.dart';
import 'package:universal_ble/universal_ble.dart';

import 'connect_retry.dart';
import 'security_write_retry.dart';

/// MTU 目标值：247 覆盖 device.info 单帧；Windows 在连接时自动协商，
/// requestMtu 返回实际生效值。
const int kCtProvTargetMtu = 247;

/// Both spellings of a 128-bit CT-Prov UUID as seen from universal_ble.
///
/// Windows hands out GATT UUIDs as the GUID it reads off the wire: it lays a
/// GUID over the 16 wire bytes, so the first three fields come out as
/// little-endian numbers while the last 8 bytes stay in wire order. A server
/// that sends the UUID in the Bluetooth SIG byte order (NE301 does; its
/// Service Data was checked byte by byte) therefore shows up as a different
/// string than the canonical text the protocol uses, and a plain string
/// comparison reports the service as missing. Matching accepts either
/// spelling; later operations reuse the string from the discovery table,
/// which is what universal_ble expects.
Set<String> _uuidSpellings(String canonical) {
  final lower = canonical.toLowerCase();
  final hex = lower.replaceAll('-', '');
  if (hex.length != 32) {
    return {lower};
  }
  // Wire bytes are the canonical (big-endian) byte sequence reversed.
  // Windows then reads a GUID over them: the first 4, 2 and 2 wire bytes as
  // little-endian integers (so each of those runs comes out reversed), the
  // remaining 8 bytes verbatim.
  final canonicalBytes = [
    for (var i = 0; i < 16; i++)
      int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  ];
  final wire = canonicalBytes.reversed.toList();
  final windowsBytes = [
    ...wire.sublist(0, 4).reversed,
    ...wire.sublist(4, 6).reversed,
    ...wire.sublist(6, 8).reversed,
    ...wire.sublist(8, 16),
  ];
  final windowsHex = windowsBytes
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join();
  final windows = [
    windowsHex.substring(0, 8),
    windowsHex.substring(8, 12),
    windowsHex.substring(12, 16),
    windowsHex.substring(16, 20),
    windowsHex.substring(20, 32),
  ].join('-');
  return {lower, windows};
}

/// The CT-Prov service and its three characteristics as spelled by the
/// platform that produced the discovery table.
final class ResolvedCtUuids {
  const ResolvedCtUuids({
    required this.service,
    required this.c2d,
    required this.d2c,
    required this.meta,
  });

  final String service;
  final String c2d;
  final String d2c;
  final String meta;
}

/// Locates the CT-Prov service and its three characteristics in a discovery
/// table under either UUID spelling. Returns null when the service is
/// absent; a present service with missing characteristics throws.
ResolvedCtUuids? resolveCtProvUuids(List<BleService> services) {
  final serviceSpellings = _uuidSpellings(kCtProvServiceUuid);
  final expected = <String, Set<String>>{
    'c2d': _uuidSpellings(kC2dCharacteristicUuid),
    'd2c': _uuidSpellings(kD2cCharacteristicUuid),
    'meta': _uuidSpellings(kMetaCharacteristicUuid),
  };
  for (final service in services) {
    if (!serviceSpellings.contains(service.uuid.toLowerCase())) continue;
    final resolved = <String, String>{};
    for (final characteristic in service.characteristics) {
      final uuid = characteristic.uuid.toLowerCase();
      for (final entry in expected.entries) {
        if (entry.value.contains(uuid)) {
          resolved[entry.key] = characteristic.uuid;
        }
      }
    }
    if (resolved.length < expected.length) {
      final missing = [
        for (final key in expected.keys)
          if (!resolved.containsKey(key)) key,
      ];
      throw StateError('CT-Prov characteristics missing: $missing');
    }
    return ResolvedCtUuids(
      service: service.uuid,
      c2d: resolved['c2d']!,
      d2c: resolved['d2c']!,
      meta: resolved['meta']!,
    );
  }
  return null;
}

final class UniversalCtGattChannel implements CtGattChannel {
  UniversalCtGattChannel._(
    this._deviceId,
    this._uuids,
    this._mtu,
    this.meta,
    this._onStep,
  );

  final String _deviceId;
  final ResolvedCtUuids _uuids;
  final int _mtu;
  final void Function(String step)? _onStep;
  final StreamController<int> _mtuChanges = StreamController<int>.broadcast();
  bool _closed = false;

  /// open 阶段读到的 META（§4.3，明文可读，作为设备身份旁证）。
  final CtMetaInfo? meta;

  /// 走完 §3 连接序列并返回就绪通道。任一步失败先回滚断开再抛错，
  /// 不留半开连接。
  ///
  /// [onStep] 接收连接序列的分步进度（连接/枚举/META/订阅/MTU/安全策略），
  /// 真机排障用：异常发生前的最后一条 step 即失败点。
  ///
  /// Windows 端插件在连接瞬间一次性缓存 GATT 表，缓存坏掉（空表/陈旧
  /// 句柄）后，后续任何基于它的操作（枚举校验、读、订阅）都会挂起或
  /// 报错，重发现无效，必须断开重连整轮重试（见 [runWithConnectRetry]）。
  /// 单轮失败自回滚，设备在断开后立刻重新广播，重连成本约 1-2 秒。
  static Future<UniversalCtGattChannel> open(
    String deviceId, {
    int targetMtu = kCtProvTargetMtu,
    Duration timeout = const Duration(seconds: 15),
    void Function(String step)? onStep,
  }) {
    return runWithConnectRetry(
      () => _openOnce(
        deviceId,
        targetMtu: targetMtu,
        timeout: timeout,
        onStep: onStep,
      ),
    );
  }

  static Future<UniversalCtGattChannel> _openOnce(
    String deviceId, {
    int targetMtu = kCtProvTargetMtu,
    Duration timeout = const Duration(seconds: 15),
    void Function(String step)? onStep,
  }) async {
    try {
      await UniversalBle.connect(deviceId, timeout: timeout);
      onStep?.call('open: connected');

      final services = await UniversalBle.discoverServices(
        deviceId,
        timeout: timeout,
      );
      final gattDump = services
          .map(
            (service) => '${service.uuid}[${service.characteristics.length}]',
          )
          .join(' ');
      onStep?.call('open: gatt ${gattDump.isEmpty ? '(empty)' : gattDump}');
      final uuids = resolveCtProvUuids(services);
      if (uuids == null) {
        throw StateError('CT-Prov service not found after discovery');
      }
      onStep?.call('open: gatt ok (${services.length} services)');

      // §4.3：META 明文可读；读不到只降级（meta=null），不阻断连接。
      CtMetaInfo? meta;
      try {
        final raw = await UniversalBle.read(
          deviceId,
          uuids.service,
          uuids.meta,
          timeout: timeout,
        );
        meta = parseMeta(raw.toList());
      } catch (_) {
        meta = null;
      }
      onStep?.call(
        'open: meta=${meta == null ? 'unreadable' : meta.name}',
      );

      await UniversalBle.subscribeIndications(
        deviceId,
        uuids.service,
        uuids.d2c,
        timeout: timeout,
      );
      onStep?.call('open: D2C subscribed');

      // Windows 在连接时已自动协商 MTU，这里只是查询实际生效值；查询偶发
      // 失败（GattSession 报错）不阻断连接：退守最小 MTU 23，本端发送按更小
      // 分片继续。对端按链路实际 MTU 发送的分片可能大于本值——接收侧重组
      // 器不校验非末片尺寸，不受影响（Android 端是真请求，失败同样退守 23）。
      int mtu;
      try {
        mtu = await UniversalBle.requestMtu(deviceId, targetMtu);
      } catch (error) {
        onStep?.call('open: mtu query failed ($error), fallback 23');
        mtu = 23;
      }
      onStep?.call('open: mtu=$mtu');

      // §4.4：C2D 要求加密链路（Just Works）。Windows PoC 在 open 前完成
      // 系统 bonding；设备端 SMP Security Request 是其他客户端的兜底。
      onStep?.call('open: security uses pre-established system bond');

      final channel = UniversalCtGattChannel._(
        deviceId,
        uuids,
        mtu,
        meta,
        onStep,
      );
      // 协商结果立刻播报，让传输层按新 MTU 重建重组器。
      channel._mtuChanges.add(mtu);
      return channel;
    } catch (_) {
      try {
        await UniversalBle.disconnect(deviceId);
      } catch (_) {
        // 回滚失败不掩盖原始错误。
      }
      rethrow;
    }
  }

  @override
  int get mtu => _mtu;

  @override
  Stream<int> get mtuChanges => _mtuChanges.stream;

  /// C2D 写入：默认 withResponse 写请求，与固件端 F_WRITE 权限一致。
  @override
  Future<void> writeC2d(List<int> frame) async {
    _ensureOpen();
    final value = Uint8List.fromList(frame);
    var securityRetries = 0;
    await writeWithSecurityRetry(
      write: () async {
        _ensureOpen();
        await UniversalBle.write(
          _deviceId,
          _uuids.service,
          _uuids.c2d,
          value,
        );
      },
      retryOn: (error) =>
          error is UniversalBleException &&
          (error.code == UniversalBleErrorCode.insufficientAuthentication ||
              error.code == UniversalBleErrorCode.insufficientEncryption),
      onRetry: (error, retry, pause) {
        securityRetries = retry;
        final milliseconds = pause.inMilliseconds;
        _onStep?.call(
          'C2D: link security pending; retry $retry in ${milliseconds}ms',
        );
      },
    );
    if (securityRetries > 0) {
      _onStep?.call(
        'C2D: link encrypted; write resumed after $securityRetries retries',
      );
    }
  }

  /// D2C 指示流（广播；open 阶段已订阅）。
  @override
  Stream<List<int>> get d2cFrames => UniversalBle.characteristicValueStream(
        _deviceId,
        _uuids.d2c,
      ).map((bytes) => bytes.toList());

  /// 再次读取 META（一般用 open 阶段的 [meta] 即可）。
  Future<CtMetaInfo?> readMeta() async {
    _ensureOpen();
    final raw = await UniversalBle.read(
      _deviceId,
      _uuids.service,
      _uuids.meta,
    );
    return parseMeta(raw.toList());
  }

  /// 退订 D2C 并断开链路（幂等）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await UniversalBle.unsubscribe(
        _deviceId,
        _uuids.service,
        _uuids.d2c,
      );
    } catch (_) {
      // 外设可能已经主动断链；清理保持幂等。
    }
    await _mtuChanges.close();
    try {
      await UniversalBle.disconnect(_deviceId);
    } catch (_) {
      // 已断开的设备本来就处于期望终态。
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('CT-Prov channel already closed');
    }
  }
}

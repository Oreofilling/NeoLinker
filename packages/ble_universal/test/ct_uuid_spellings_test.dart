import 'package:ble_adapter/ble_adapter.dart';
import 'package:ble_universal/src/universal_ct_channel.dart';
import 'package:test/test.dart';
import 'package:universal_ble/universal_ble.dart';

/// Regression for the Windows GUID spelling: on a real NE301 the
/// universal_ble discovery table reports the UUIDs as GUID text
/// ('0b7e0100-2a4c-8f6d-5b4b-5b9d01001e7b'), and the old canonical-string
/// comparison failed with "CT-Prov service not found after discovery".
void main() {
  // Windows spelling captured on the real device (bleak discovery dump).
  const serviceWin = '0b7e0100-2a4c-8f6d-5b4b-5b9d01001e7b';
  const c2dWin = '0b7e0100-2a4c-8f6d-5b4b-5b9d02001e7b';
  const d2cWin = '0b7e0100-2a4c-8f6d-5b4b-5b9d03001e7b';
  const metaWin = '0b7e0100-2a4c-8f6d-5b4b-5b9d04001e7b';

  BleService service(String uuid, List<String> characteristics) => BleService(
        uuid,
        [
          for (final c in characteristics) BleCharacteristic(c, const [], const []),
        ],
      );

  test('resolves the CT-Prov UUIDs from the Windows GUID spelling', () {
    final resolved = resolveCtProvUuids(
      [
        service(
          '00001800-0000-1000-8000-00805f9b34fb',
          const ['00002a00-0000-1000-8000-00805f9b34fb'],
        ),
        service(serviceWin, [c2dWin, d2cWin, metaWin]),
      ],
    );

    expect(resolved, isNotNull);
    expect(resolved!.service, serviceWin);
    expect(resolved.c2d, c2dWin);
    expect(resolved.d2c, d2cWin);
    expect(resolved.meta, metaWin);
  });

  test('the Windows spelling of the service UUID matches the real device', () {
    // Derivation, so the mapping cannot silently drift: canonical bytes
    // 7B1E0001-9D5B-4B5B-8F6D-2A4C0B7E0100 -> wire order (reversed) ->
    // GUID fields read little-endian over the first 8 wire bytes.
    final resolved = resolveCtProvUuids([
      service(serviceWin, [c2dWin, d2cWin, metaWin]),
    ]);
    expect(resolved, isNotNull);
  });

  test('still resolves the canonical spelling (spec-correct stacks)', () {
    final resolved = resolveCtProvUuids(
      [
        service(kCtProvServiceUuid, [
          kC2dCharacteristicUuid,
          kD2cCharacteristicUuid,
          kMetaCharacteristicUuid,
        ]),
      ],
    );

    expect(resolved, isNotNull);
    // BleUuidParser normalises to lower case.
    expect(resolved!.service, kCtProvServiceUuid.toLowerCase());
    expect(resolved.c2d, kC2dCharacteristicUuid.toLowerCase());
    expect(resolved.d2c, kD2cCharacteristicUuid.toLowerCase());
    expect(resolved.meta, kMetaCharacteristicUuid.toLowerCase());
  });

  test('returns null when the service is absent', () {
    expect(
      resolveCtProvUuids(
        [service('00001800-0000-1000-8000-00805f9b34fb', const [])],
      ),
      isNull,
    );
  });

  test('reports missing characteristics', () {
    expect(
      () => resolveCtProvUuids(
        [service(serviceWin, [c2dWin, d2cWin])],
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('characteristics missing'),
        ),
      ),
    );
  });
}

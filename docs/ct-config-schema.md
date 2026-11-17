# CT-Prov/1 Configuration Schema

| Item | Value |
| --- | --- |
| Document status | Draft v2.0, restructured to the config-section model matching the actual NE101/NE301 implementations |
| Updated | 2026-10-28 |
| Applies to | the `data` payloads of `config.set` and `config.get` |
| Depends on | [CT-Prov/1 Protocol](./ct-prov-protocol.md) |

This document defines only the fields, types, constraints, and examples of
each config section inside a `config.set` payload, plus the mapping to the
actual NE101/NE301 storage. Request envelopes, capability declarations,
scanning, error codes, and timeouts are in the protocol document.

## 1. General conventions

- JSON is UTF-8; the top level must be an object; a BOM is forbidden; field
  names are case-sensitive; integers must not be expressed as floats.
- Strings are at most 256 bytes by default; password-type fields are at most
  128 bytes. Password-type fields may only travel over an encrypted link
  (protocol §4.4).
- `config.set` is a transaction-free overwrite: `ok=true` only means the
  payload was validated and written to persistent storage, not that it has
  taken effect. The protocol reports no network, address, or service
  verification results.
- The payload is a "section name → section object" mapping; only sections
  present are written, fields within a section are replaced as a whole, and
  there is no field-level merge.
- The capability response's `fields` decides what may be submitted; fields
  not listed must not be submitted, otherwise the device returns
  `FIELD_NOT_SUPPORTED`. The examples in this document show the full shape
  when a capability declares every field.
- Fields marked "optional" in the tables fall back to the stated default
  behavior when omitted; fields not marked optional must be provided whenever
  the capability lists them.
- NE101 and NE301 are both DHCP today; the protocol defines no static-IP
  fields. Wi-Fi security is inferred by the device from whether a password
  is provided: a `password` means WPA2/WPA3; omitting it or an empty string
  means an open network.

## 2. Config section overview

| Section | kind | Common fields | NE101 | NE301 |
| --- | --- | --- | --- | --- |
| `wifi` | network | ssid, password, bssid | ssid, password | ssid, password, bssid |
| `cellular` | network | apn, username, password, pin, auth | apn, username, password, pin, auth | apn, username, password, pin, auth, roaming |
| `halow` | network | ssid, password, country | ssid, password, country | per SKU |
| `ethernet` | network | no fields | not applicable | no fields (PoE power) |
| `comm` | selector | type | not declared (firmware auto-probe) | type |
| `mqtt` | service | enable, host, port, client_id, username, password, tls, topic, qos | all supported except bssid-class differences | mapped to hostname/client_id/certificate paths |
| `webhook` | service | enable, url, secret, header | enable (push:mode), url, header | enable, url, secret |

The `comm` section only appears in the capabilities of devices that support
explicitly selecting the network type; on NE101 the network type is written
back by `netModule_check()` hardware probing, so the section is not offered.

## 3. wifi section

```json
{
  "ssid": "Office-2.4G",
  "password": "example-password"
}
```

| Field | Type | Constraint |
| --- | --- | --- |
| `ssid` | string | 1–31 bytes, target network name; for hidden networks enter the SSID directly |
| `password` | string | password-type field, 8–63 bytes; omitted or empty string means an open network |
| `bssid` | string | optional; 6 colon-separated hex groups, locks onto a specific AP; must not be submitted unless declared in capabilities |

Security type is not a separate field: the device infers open versus WPA
from whether a `password` is provided.

## 4. cellular section

```json
{
  "apn": "cmiot.iot",
  "username": "device",
  "password": "example-password",
  "pin": "1234",
  "auth": "chap",
  "roaming": false
}
```

| Field | Type | Constraint |
| --- | --- | --- |
| `apn` | string | 1–64 bytes APN; omitted when the capability declares a zero-config SIM (`fields=[]`) |
| `username` | string | optional; ≤64 bytes |
| `password` | string | password-type field, optional; ≤128 bytes |
| `pin` | string | password-type field, optional; 4–8 digits |
| `auth` | string | optional; `none`, `pap`, `chap`, `pap_or_chap`, default `none` |
| `roaming` | bool | optional; whether roaming is allowed; must not be submitted unless declared in capabilities |

Carrier selection, serial baud rate, and other module-private parameters
are not part of the common sections; they are maintained in the device's
local management UI.

## 5. halow section

```json
{
  "ssid": "CT-HaLow",
  "password": "example-password",
  "country": "CN"
}
```

| Field | Type | Constraint |
| --- | --- | --- |
| `ssid` | string | 1–32 bytes, target network identifier |
| `password` | string | password-type field, 8–63 bytes; omitted or empty string means an open network |
| `country` | string | optional; 2 uppercase country/region code letters, e.g. `CN`, `US` |

## 6. ethernet section

```json
{}
```

Ethernet/PoE devices work as soon as plugged in (DHCP); this section has no
writable fields. Devices usually present it in capabilities with
`configurable=false`, purely to show existence; PoE is a power attribute,
see the `power` field of `device.info`.

## 7. comm section (optional)

```json
{
  "type": "wifi"
}
```

| Field | Type | Constraint |
| --- | --- | --- |
| `type` | string | one of `wifi`, `cellular`, `halow`, `ethernet`, and must be a network section declared in capabilities |

Only devices that explicitly select the network type declare this section.
Writing it switches the active network; when submitted in the same request
as network sections, the network sections are applied first, then the
switch.

## 8. mqtt section

```json
{
  "enable": true,
  "host": "mqtt.example.com",
  "port": 8883,
  "client_id": "NE101202610270001",
  "username": "device",
  "password": "example-secret",
  "tls": true,
  "topic": "ct/NE101202610270001/data",
  "qos": 1
}
```

| Field | Type | Constraint |
| --- | --- | --- |
| `enable` | bool | whether the MQTT egress is enabled; on devices supporting dual egress it can coexist with `webhook.enable`, per device policy |
| `host` | string | domain name or IP literal, ≤128 bytes |
| `port` | uint16 | `1..65535`; 8883 recommended when TLS is enabled |
| `client_id` | string | optional; ≤64 bytes; when omitted the device generates it from `serial_number` |
| `username` | string | optional; ≤64 bytes |
| `password` | string | password-type field, optional; ≤128 bytes; omitted means anonymous access |
| `tls` | bool | optional; whether TLS is enabled, default `false` |
| `topic` | string | optional; ≤128 bytes, data-report topic, must not contain `+`/`#` wildcards |
| `qos` | uint8 | optional; `0..2`, default `0` |

Certificate fields (CA names, client-certificate paths) are not part of the
common sections; they are maintained in the device's local management UI.

## 9. webhook section

```json
{
  "enable": true,
  "url": "https://ops.example.com/hooks/camera",
  "secret": "whsec_example",
  "header": "X-API-Key: abc123"
}
```

| Field | Type | Constraint |
| --- | --- | --- |
| `enable` | bool | whether the Webhook egress is enabled |
| `url` | string | absolute http/https URI, ≤256 bytes, https recommended |
| `secret` | string | password-type field, optional; ≤128 bytes signing secret; must not be submitted unless declared in capabilities |
| `header` | string | optional; ≤256 bytes, an extra request header in `Key: Value` form; must not be submitted unless declared in capabilities |

The signing algorithm for `secret` (e.g. HMAC-SHA256 and the request-header
name) is defined by product documentation. Event filtering, timeouts, and
other extension fields are added per capability declaration.

## 10. Platform implementation mapping

### 10.1 NE101 (ESP32-S3, NVS key-value store)

| Common field | NE101 NVS key |
| --- | --- |
| wifi.ssid / wifi.password | `wifi:ssid` / `wifi:password` |
| cellular.apn | `cat1:apn` |
| cellular.username | `cat1:user` |
| cellular.password | `cat1:password` |
| cellular.pin | `cat1:pin` |
| cellular.auth | `cat1:authType` |
| halow.* | reuses `wifi:ssid`, `wifi:password`; region code stored in `dev:country` |
| comm.type | not applicable; `dev:netmod` is written back by `netModule_check()` hardware probing |
| mqtt.enable / host / port | `mqtt:enable` / `mqtt:host` / `mqtt:port` |
| mqtt.client_id / qos | `mqtt:clientId` / `mqtt:qos` |
| mqtt.username / password | `mqtt:user` / `mqtt:password` |
| mqtt.tls / topic | `mqtt:tlsEnable` / `mqtt:topic` |
| webhook.enable | `push:mode` (0=MQTT, 1=Webhook) |
| webhook.url / header | `whk:url` / `whk:header` |
| webhook.secret | not supported; not declared in capabilities |

Apply timing: after the NVS write, `netModule_open()` applies it at the next
network bring-up or reboot; `config.set.result` reports `apply: reconnect`.

### 10.2 NE301 (STM32N6570 + Si91x + W5500, Services architecture)

| Common field | NE301 implementation |
| --- | --- |
| wifi.ssid / password / bssid | Wi-Fi service STA configuration (`/api/v1/system/network/wifi`) |
| cellular.apn / username / password | Cellular service settings `apn/username/password` |
| cellular.pin / auth / roaming | `pin_code` / `authentication` (0=None, 1=PAP, 2=CHAP) / `enable_roaming` |
| comm.type | switched via `/api/v1/system/network/comm` (`wifi`/`cellular`/`poe`→`ethernet`) |
| ethernet | comm type `poe`, no separate fields |
| mqtt.host / port / client_id | MQTT service `connection.hostname/port/client_id` |
| mqtt.username / password | MQTT service `authentication.username/password` |
| mqtt.tls | derived from CA-certificate presence; mapped to certificate configuration state on write |
| mqtt.topic / qos | MQTT service `topics` report topic and QoS configuration |
| webhook.enable / url / secret | Webhook service `enable/url/secret` |
| webhook.header | subject to the device Web API; not declared in capabilities when unsupported |

Apply timing: after saving, the corresponding Service applies it per its own
policy; `apply` reports `immediate` or `reconnect`.

The field limits on both platforms (e.g. `ssid[32]`, `url[256]`) are the
source of the constraints in this document; common constraints take the
intersection or the stricter value of the two platforms, and single-platform
private capabilities are always gated by capability declaration.

## 11. Extension rules

- New fields must first be added to the capability `fields` declaration; the
  Client builds forms from capabilities, and the Server returns
  `FIELD_NOT_SUPPORTED` for undeclared fields.
- Unrecognized section names are hidden or shown as non-configurable by the
  Client; the Server returns `SECTION_NOT_SUPPORTED` and must not guess by
  analogy with known sections.
- Single-platform private fields (e.g. `bssid`, `roaming`, `secret`) stay in
  the common schema but must be capability-gated; devices must never be
  required to support them unconditionally.
- Changes to field constraints count as schema evolution and ship with a
  protocol version bump.

<div align="right">

**English** | [简体中文](README.zh-CN.md)

</div>

# NeoLinker

[![CI](https://github.com/camthink-ai/NeoLinker/actions/workflows/ci.yml/badge.svg)](https://github.com/camthink-ai/NeoLinker/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg?logo=apache)](LICENSE)

NeoLinker is a Windows desktop tool for discovering, provisioning, and
configuring **CamThink NE-series low-power AI cameras** — over Bluetooth LE,
the device's own softAP, or the local network.

It is a companion tool, not firmware: put a camera into configuration mode,
pick it up in NeoLinker, and the app walks you through
connect → configure → verify, leaving a per-device receipt you can keep or
export. The UI is bilingual (English / 中文) with light and dark themes.

## Features

- **Environment self-check** — on launch the app checks each transport
  (BLE adapter, WLAN, LAN) and shows readiness before you start.
- **Multi-channel discovery** — BLE advertisement scan, softAP SSID scan,
  and LAN discovery ([CT-Disc](#device-support)), with model filtering,
  pagination, and QR-code entry (scan or upload the code printed with the
  device).
- **Phase-driven provisioning** — the session moves through connect →
  read capabilities → configure → deliver → result, with link-lost
  detection and in-place reconnect if the device drops.
- **Capability-driven config forms** — the device reports the config
  modules it supports (Wi-Fi, cellular, MQTT, webhook, …); forms are
  built from that report and prefilled with current values.
- **Embedded device console** — NE503 devices expose a management web
  page; it opens inside the app (WebView2) instead of a browser.
- **Receipts & history** — every completed session writes a plain-text
  receipt per device; past sessions are listed and exportable.

## Device support

| Device | BLE (CT-Prov/1) | SoftAP (CT-Prov over HTTP) | LAN (CT-Disc) | Notes |
| ------ | :---: | :---: | :---: | ----- |
| NE101  | ✅ | ✅ | — | Primary target; BLE leg field-tested end to end |
| NE301  | 🚧 | ✅ | — | SoftAP first; BLE planned. Comm-module config (Wi-Fi / cellular / MQTT / webhook) |
| NE503  | — | — | ✅ | Discovery + embedded management console; newest, least field-tested leg |

Field testing so far has focused on NE101. NE301 currently provisions over
softAP only — BLE support is planned but not available yet; NE503 support is
newer.

## Download

Grab the latest `NeoLinker_v*_windows_x64.zip` from
[Releases](https://github.com/camthink-ai/NeoLinker/releases), unzip, and run
`NeoLinker.exe`. No installer.

Requirements: Windows 10/11 x64, the WebView2 Evergreen runtime (preinstalled
on Windows 11 and most updated Windows 10), and a Bluetooth adapter for the
BLE channel.

## Build from source

Prerequisites:

- Windows 10/11 x64
- [Flutter 3.47.8](https://docs.flutter.dev/get-started/install/windows)
  (pinned — newer stable versions currently fail `flutter analyze` on
  deprecation infos this tree hasn't migrated to yet; see
  [ci.yml](.github/workflows/ci.yml))
- Visual Studio 2022 Build Tools with the *Desktop development with C++*
  workload
- `nuget.exe` on `PATH` (the WebView2 plugin restores its NuGet package at
  build time)

```bash
git clone https://github.com/camthink-ai/NeoLinker.git
cd neolinker/apps/desktop_app
flutter pub get
flutter gen-l10n          # regenerate localizations after ARB edits
flutter analyze
flutter test
flutter run -d windows    # or: flutter build windows --release
```

CI runs analyze + test for every package on every push; the Windows
release build runs only on `v*` tags and manual dispatch. Entry point:
[tool/ci.sh](tool/ci.sh).

## Repository layout

```text
neolinker/
├── apps/desktop_app/          # Windows app (Flutter)
├── packages/
│   ├── neolinker_ui/          # Design system: OKLCH tokens + base widgets
│   ├── ct_prov_core/          # CT-Prov/1 codec: fragmentation + envelopes + error codes
│   ├── test_vectors/          # CT-Prov/1 golden vectors (adverts / fragments / envelopes)
│   ├── discovery_domain/      # Discovery domain model, three channels unified
│   ├── provisioning_session/  # Provisioning session state machine
│   ├── communication_domain/  # Config node schemas + validation
│   ├── ble_universal/         # universal_ble adapter (scan bridge + GATT channel)
│   ├── ble_adapter/           # CT-Prov BLE adapter (advert parsing + GATT transport)
│   ├── softap_transport/      # CT-Prov over softAP HTTP (same session semantics as BLE)
│   ├── ap_discovery_adapter/  # SoftAP discovery adapter (Windows WLAN SSID scan)
│   └── ct_disc_adapter/       # CT-Disc LAN discovery adapter (multicast announce listener)
├── design/                    # Brand mark (chain-N): SVG masters + PNG exports
└── tool/                      # CI entry, design-token and app-icon generators
```

## Development notes

- **Localizations** — UI copy lives in
  `apps/desktop_app/lib/l10n/app_*.arb` (zh is the template language, en the
  second). Run `flutter gen-l10n` after editing; analyze fails on stale
  generated files. Components in `neolinker_ui` never hardcode copy — labels
  are passed in, already localized.
- **Design tokens** — `packages/neolinker_ui/lib/src/tokens.dart` is
  generated by `tool/gen_tokens.py`; don't hand-edit it. Widgets read colors
  via `context.nl.*`, never raw hex.
- **Brand mark** — masters live in `design/` (`logo.svg`, `logo-tile.svg`);
  the in-app mark is the `NLLogo` widget; icons are regenerated with
  `tool/gen_app_icon.py`. Keep the three in sync when geometry changes.

## Documentation

The wire protocols this app implements are published in [`docs/`](docs/):

- [CT-Prov/1 — Communication Provisioning Protocol](docs/ct-prov-protocol.md)
  (BLE GATT + softAP HTTP bindings)
- [CT-Prov/1 — Configuration Schema](docs/ct-config-schema.md)
  (fields of every `config.set` section)
- [CT-Disc — Device Discovery & Management Protocol](docs/ct-disc-protocol.md)
  (UDP multicast + MQTT)

## Roadmap

- NE503 management leg is maturing (LAN API transport, embedded console).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). This project follows the
[Contributor Covenant](CODE_OF_CONDUCT.md); security reports go through
[SECURITY.md](SECURITY.md), not public issues.

## License

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 CamThink Team.

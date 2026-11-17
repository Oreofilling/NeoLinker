# CLAUDE.md

Guidance for Claude Code (or any coding agent) working in this repository.
Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Commands

Work happens inside `apps/desktop_app` or one of the `packages/*`; there is
no top-level build.

```bash
cd apps/desktop_app
flutter pub get
flutter gen-l10n          # after any ARB edit — before analyze
flutter analyze           # warnings are fatal in CI
flutter test
flutter build windows --release
```

CI runs analyze + test + a release build for every package on each push
(`tool/ci.sh`).

## Non-negotiables

- **Flutter 3.47.8 pinned** — newer stable versions currently fail
  `flutter analyze` on deprecation infos this tree hasn't migrated to.
- **`flutter gen-l10n` before `flutter analyze`** — generated localization
  files are gitignored; analyze fails on stale generated output.
- **English everywhere** — identifiers, comments, commit messages, CI
  config, and error reason strings. UI copy lives only in the ARB files
  (`apps/desktop_app/lib/l10n/app_*.arb`; zh is the template language, en
  the second language).
- **`neolinker_ui` components never hardcode copy** — labels are passed in,
  already localized, by the app layer.
- **Design tokens are generated** — `packages/neolinker_ui/lib/src/tokens.dart`
  comes from `tool/gen_tokens.py`; never hand-edit it. Widgets read colors
  via `context.nl.*`, never raw hex.
- **Brand mark stays in sync** — when the geometry changes, update
  `design/logo.svg`, the `NLLogo` widget, and `tool/gen_app_icon.py`
  together (all share the same 0..96 coordinate space).
- **Conventional Commits** (`feat:`, `fix:`, `docs:`, …); subject under 50
  characters, imperative mood.
- **No secrets or internal infrastructure details** in code, docs, tests,
  or examples.

## Where things are

- Protocol wire format: `packages/ct_prov_core` + `packages/test_vectors`
  (golden vectors); specs in [docs/ct-prov-protocol.md](docs/ct-prov-protocol.md)
  and [docs/ct-config-schema.md](docs/ct-config-schema.md).
- Discovery channels (BLE advert scan / softAP SSID / CT-Disc multicast):
  `packages/discovery_domain` plus the adapters under `packages/`.
- Session phases (connect → capabilities → configure → deliver → receipt):
  `packages/provisioning_session`.
- Config-section schemas and validation: `packages/communication_domain`.
- Windows is the only supported platform; do not add platform branches for
  others without a plan to test them.

# Contributing to NeoLinker

Thanks for your interest in improving NeoLinker! Bug reports, fixes, docs,
and translation improvements are all welcome. For feature work, please open
an issue first so we can align on scope before you invest time.

## Setting up

Follow the build instructions in the
[README](README.md#build-from-source) — the short version:

1. Install Flutter 3.47.8 (the version CI pins; newer stable versions
   currently fail `flutter analyze` on deprecation infos this tree hasn't
   migrated to).
2. Install Visual Studio 2022 Build Tools with the *Desktop development
   with C++* workload, and make `nuget.exe` reachable on `PATH` (the
   WebView2 plugin restores a NuGet package at build time).
3. From `apps/desktop_app`:

   ```bash
   flutter pub get
   flutter gen-l10n
   flutter analyze
   flutter test
   ```

`tool/ci.sh` runs the same per-package analyze + test + release build
pipeline that CI runs — use it as your pre-push check.

## Where things live

This is a monorepo: the Windows app is in `apps/desktop_app`, and protocol,
discovery, session, and UI logic live in versioned packages under
`packages/` (see the [layout map](README.md#repository-layout)). Generally,
fixes belong in the smallest package that contains the problem; the app
mostly wires packages together.

## Code conventions

- **Language** — code, identifiers, and new code comments are in English.
  UI copy is never hardcoded: add strings to both
  `apps/desktop_app/lib/l10n/app_zh.arb` (template) and `app_en.arb`, then
  run `flutter gen-l10n`.
- **Design tokens** — widgets take colors from `context.nl.*`
  (the generated token set in `neolinker_ui`), never raw hex or
  `Colors.*` literals.
- **Style** — match the surrounding code; `flutter analyze` must be clean
  (warnings are fatal in CI, not just errors).
- **Tests** — behavior changes come with tests. Widget tests pump real
  widgets; protocol-level changes should extend the golden vectors in
  `packages/test_vectors` where applicable.

## Commit messages

Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`,
`refactor:`, `perf:`, `ci:`), imperative subject line ≤ 50 chars, no
trailing period.

## Pull requests

- Keep PRs focused; one logical change per PR.
- CI (analyze + test + Windows release build) must pass.
- Describe what changed and why; link related issues.
- By contributing, you agree your contributions are licensed under the
  [Apache-2.0](LICENSE) license of this repository.

## Reporting bugs

Use the issue templates (bug report / feature request). When reporting a
bug, include the app version (shown in the sidebar footer), Windows
version, device model, and the transport you used — and attach the runtime
log at `%TEMP%\neolinker_desktop.log` if you can.

**Security issues are not reported as public issues** — see
[SECURITY.md](SECURITY.md).

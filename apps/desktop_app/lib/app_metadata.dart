/// App identity constants (v7d). [appVersion] is shown in the sidebar
/// footer and heads exported receipts and run history. pubspec.yaml
/// `version:` is the source of truth: the Windows version resource
/// (FLUTTER_VERSION macros in windows/runner/Runner.rc) and the macOS
/// bundle (FLUTTER_BUILD_NAME in macos/Runner/Info.plist) follow it, while
/// [appVersion] and `msix_version` are hand-kept copies —
/// test/app_metadata_test.dart pins both to it.
const String appVersion = '0.3.0';

/// Mirrors the `ProductName` / `FileDescription` literal in Runner.rc;
/// the resource reads its own string, so change both together.
const String appProductName = 'NeoLinker Device Provisioning';

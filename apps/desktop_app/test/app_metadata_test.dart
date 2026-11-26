// The app version is kept in more than one place. pubspec.yaml is the
// source of truth: the Windows version resource (Runner.rc reads the
// FLUTTER_VERSION macros) and the release tags follow it. The in-app string
// and the MSIX version are hand-kept copies, and v0.3.0 shipped with both
// still on 0.2.0 — the sidebar footer and every exported receipt named the
// wrong version. These tests pin the copies to the source.
import 'dart:io';

import 'package:desktop_app/app_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  /// Value of a `<key>: <value>` line in pubspec.yaml, at any indentation.
  String pubspecValue(String key) {
    final match = RegExp(
      r'^\s*' '$key:' r'\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no "$key:" line');
    return match!.group(1)!;
  }

  /// The pubspec version without its optional `+<build>` suffix, which is
  /// what users see.
  String versionName() => pubspecValue('version').split('+').first;

  test('appVersion matches the pubspec version', () {
    expect(appVersion, versionName());
  });

  test('msix_version is the pubspec version plus a build component', () {
    expect(pubspecValue('msix_version'), '${versionName()}.0');
  });
}

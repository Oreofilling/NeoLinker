/// "Guide the user to the system Location Services page": the macOS
/// counterpart of `openWifiSettings`. CoreWLAN hides Wi-Fi SSIDs unless
/// the app is authorized for Location Services, and a refusal is only
/// fixable there. Injectable so widget tests observe the launch without
/// shelling out.
library;

import 'dart:io';

/// Launches the system Location Services page; returns whether the launch
/// command succeeded.
typedef LocationSettingsOpener = Future<bool> Function();

/// Opens the Location Services privacy pane on macOS; other platforms
/// report false.
Future<bool> openLocationSettings() async {
  if (!Platform.isMacOS) return false;
  const pane =
      'x-apple.systempreferences:com.apple.preference.security'
      '?Privacy_LocationServices';
  final result = await Process.run('open', const [pane]);
  return result.exitCode == 0;
}

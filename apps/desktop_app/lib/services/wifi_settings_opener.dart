/// "Guide the user to the system Wi-Fi page" (M5 task 1): opens the
/// Windows Wi-Fi settings page when the AP channel is limited because
/// the WLAN adapter is disabled. Injectable so widget tests observe
/// the launch without shelling out.
library;

import 'dart:io';

/// Launches the system Wi-Fi settings page; returns whether the launch
/// command succeeded.
typedef WifiSettingsOpener = Future<bool> Function();

/// Opens the system Wi-Fi settings page: `ms-settings:network-wifi` on
/// Windows, the Network preference pane on macOS. Other platforms report
/// false.
Future<bool> openWifiSettings() async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', const [
      '/c',
      'start',
      '',
      'ms-settings:network-wifi',
    ]);
    return result.exitCode == 0;
  }
  if (Platform.isMacOS) {
    final result = await Process.run('open', const [
      '/System/Library/PreferencePanes/Network.prefPane',
    ]);
    return result.exitCode == 0;
  }
  return false;
}

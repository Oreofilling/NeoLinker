/// Open the device web console in the user's default browser after the
/// softAP join succeeds (web mode). Injectable so controller/widget tests
/// observe the launch without shelling out — same pattern as
/// [openWifiSettings].
library;

import 'dart:io';

/// Launches the device web page; returns whether the launch command
/// succeeded (the browser owns everything after that).
typedef DeviceWebOpener = Future<bool> Function(Uri url);

/// Opens [url] in the default browser: cmd `start` on Windows, `open` on
/// macOS. Other platforms report false (no shell opener wired yet).
Future<bool> openDeviceWebPage(Uri url) async {
  if (Platform.isWindows) {
    final result = await Process.run('cmd', [
      '/c',
      'start',
      '',
      url.toString(),
    ]);
    return result.exitCode == 0;
  }
  if (Platform.isMacOS) {
    final result = await Process.run('open', [url.toString()]);
    return result.exitCode == 0;
  }
  return false;
}

import Cocoa
import CoreWLAN
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // macOS counterpart of the custom Windows runner's channels: the
    // CoreWLAN Wi-Fi scan/join surface for the device softAP chain
    // (Dart side: lib/services/mac_wlan.dart).
    if let controller = NSApp.windows.first?.contentViewController as? FlutterViewController {
      MacWlanChannel.attach(to: controller)
    }
    super.applicationDidFinishLaunching(notification)
  }
}

/// `neolinker/mac_wlan` platform channel.
///
/// Methods (see mac_wlan.dart for the Dart-side contract):
/// - `currentSsid` -> String? — CoreWLAN hides the current SSID without
///   Location Services on 10.15+, so `networksetup -getairportnetwork`
///   (a system tool, not location-gated) is the fallback.
/// - `scan` -> [{ssid, rssi(dBm), security}] — requires Location Services
///   authorization; a denial raises `location_denied` and the Dart side
///   reports an empty pass (QR / manual entry take over).
/// - `join` {ssid, password?} -> Bool — CoreWLAN associate when the SSID
///   is scannable, else `networksetup -setairportnetwork`.
/// - `disconnect` -> Bool.
///
/// CoreWLAN calls and the networksetup subprocess are slow (seconds), so
/// everything runs off the main thread; results hop back to main.
enum MacWlanChannel {
  static let name = "neolinker/mac_wlan"
  private static let networksetup = "/usr/sbin/networksetup"

  static func attach(to controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: name, binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      let client = CWWiFiClient.shared()
      switch call.method {
      case "currentSsid":
        DispatchQueue.global(qos: .userInitiated).async {
          let ssid = currentSsid(client: client)
          DispatchQueue.main.async { result(ssid) }
        }
      case "scan":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try scan(client: client, result: result)
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "no_interface", message: "\(error)", details: nil))
            }
          }
        }
      case "join":
        let args = call.arguments as? [String: Any]
        let ssid = args?["ssid"] as? String ?? ""
        let password = args?["password"] as? String
        DispatchQueue.global(qos: .userInitiated).async {
          let ok = join(client: client, ssid: ssid, password: password)
          DispatchQueue.main.async { result(ok) }
        }
      case "disconnect":
        DispatchQueue.global(qos: .userInitiated).async {
          let ok = (try? client.interface()?.disassociate()) != nil
          DispatchQueue.main.async { result(ok) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Current link

  static func currentSsid(client: CWWiFiClient) -> String? {
    if let ssid = client.interface()?.ssid(), !ssid.isEmpty { return ssid }
    let (service, _) = wifiServiceAndDevice()
    let out = runTool(networksetup, ["-getairportnetwork", service])
    // Output line: "Current Wi-Fi Network: NE101_2001CA" (or an error text
    // when not associated).
    guard let line = out.split(separator: "\n").first(where: {
      $0.hasPrefix("Current Wi-Fi Network:")
    }) else { return nil }
    let ssid = line.dropFirst("Current Wi-Fi Network:".count)
      .trimmingCharacters(in: .whitespaces)
    return ssid.isEmpty ? nil : ssid
  }

  // MARK: - Scan

  static func scan(client: CWWiFiClient, result: @escaping FlutterResult) throws {
    // macOS 10.15+ gates SSID scans behind Location Services. Request
    // authorization once on the notDetermined path; denied/restricted
    // surfaces as location_denied so the Dart poll reports nothing.
    switch CWWiFiClient.authorizationState() {
    case .authorized:
      break
    case .notDetermined:
      CWWiFiClient.requestAuthorization { _ in }
      DispatchQueue.main.async {
        result(FlutterError(code: "location_denied", message: "authorization requested", details: nil))
      }
      return
    case .restricted, .denied:
      DispatchQueue.main.async {
        result(FlutterError(code: "location_denied", message: "location access denied", details: nil))
      }
      return
    @unknown default:
      DispatchQueue.main.async {
        result(FlutterError(code: "location_denied", message: "unknown state", details: nil))
      }
      return
    }
    guard let iface = client.interface() else {
      DispatchQueue.main.async {
        result(FlutterError(code: "no_interface", message: "no Wi-Fi interface", details: nil))
      }
      return
    }
    let networks = try iface.scanForNetworks(withSSID: nil)
    let rows: [[String: Any]] = networks.map { network in
      [
        "ssid": network.ssid ?? "",
        "rssi": Int(network.rssiValue),
        "security": securityName(network),
      ]
    }
    DispatchQueue.main.async { result(rows) }
  }

  // MARK: - Join

  static func join(client: CWWiFiClient, ssid: String, password: String?) -> Bool {
    guard !ssid.isEmpty else { return false }
    // Path 1: CoreWLAN associate. Needs the CWNetwork object, i.e. a
    // scan, i.e. location authorization; skip silently when unavailable.
    if CWWiFiClient.authorizationState() == .authorized,
       let iface = client.interface(),
       let networks = try? iface.scanForNetworks(withSSID: ssid as NSString),
       let network = networks.first(where: { $0.ssid == ssid }) {
      do {
        if let password, !password.isEmpty {
          return try iface.associate(toNetwork: network, password: password)
        }
        return try iface.associate(toNetwork: network)
      } catch {
        // Fall through to networksetup.
      }
    }
    // Path 2: networksetup join by SSID string — no scan or location
    // needed, works for the open device APs; the exit text says so when
    // the join fails.
    let (service, _) = wifiServiceAndDevice()
    var args = ["-setairportnetwork", service, ssid]
    if let password, !password.isEmpty { args.append(password) }
    let out = runTool(networksetup, args)
    let lower = out.lowercased()
    return !lower.contains("failed") && !lower.contains("error")
  }

  // MARK: - Helpers

  /// Resolves the Wi-Fi service name (for networksetup) and device name
  /// from `-listallhardwareports`; falls back to the conventional
  /// service "Wi-Fi" on device en0.
  static func wifiServiceAndDevice() -> (service: String, device: String) {
    let out = runTool(networksetup, ["-listallhardwareports"])
    var blocks = out.split(separator: "\n\n").map { block -> (String, String)? in
      var service = ""
      var device = ""
      for line in block.split(separator: "\n") {
        if line.hasPrefix("Hardware Port:") {
          service = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("Device:") {
          device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
        }
      }
      guard !service.isEmpty, !device.isEmpty else { return nil }
      return (service, device)
    }.compactMap { $0 }
    if blocks.isEmpty { blocks = [("Wi-Fi", "en0")] }
    // Prefer the airport-looking device (en*); the first block otherwise.
    let pick = blocks.first(where: { $0.device.hasPrefix("en") }) ?? blocks[0]
    return pick
  }

  static func securityName(_ network: CWNetwork) -> String {
    if network.supportsSecurity(.none) { return "open" }
    if network.supportsSecurity(.wpa3) { return "wpa3" }
    if network.supportsSecurity(.wpa2) { return "wpa2" }
    if network.supportsSecurity(.wpa) { return "wpa" }
    if network.supportsSecurity(.wep) { return "wep" }
    return "enterprise"
  }

  @discardableResult
  static func runTool(_ path: String, _ arguments: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
      try task.run()
    } catch {
      return "error: \(error)"
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
  }
}

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
/// - `scan` -> [{ssid, rssi(dBm)}] — requires Location Services
///   authorization; a denial raises `location_denied` and the Dart side
///   reports an empty pass (QR / manual entry take over).
/// - `join` {ssid, password?} -> Bool — CoreWLAN associate when the SSID
///   is scannable, else `networksetup -setairportnetwork`.
/// - `disconnect` -> Bool.
/// - `adapterState` -> {present: Bool, powerOn: Bool} — whether a WLAN
///   interface exists and whether its radio is on. Reads no SSIDs, so it
///   needs no Location Services (the self-check calls it on every probe).
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
      case "adapterState":
        // Power state only: `client.interface()` and `powerOn()` read no
        // SSID, so unlike `scan` this never triggers a location prompt.
        DispatchQueue.global(qos: .userInitiated).async {
          let iface = client.interface()
          let present = iface != nil
          let powerOn = iface?.powerOn() ?? false
          let state: [String: Any] = ["present": present, "powerOn": powerOn]
          DispatchQueue.main.async { result(state) }
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
    // macOS 10.15+ gates SSID scans behind Location Services; the first
    // scanForNetworks call triggers the system prompt, and a scan without
    // authorization throws. Map that (and any other CoreWLAN refusal) to
    // location_denied so the Dart poll reports a quiet pass and QR/manual
    // entry take over.
    guard let iface = client.interface() else {
      DispatchQueue.main.async {
        result(FlutterError(code: "no_interface", message: "no Wi-Fi interface", details: nil))
      }
      return
    }
    do {
      let networks = try iface.scanForNetworks(withSSID: nil)
      let rows: [[String: Any]] = networks.map { network in
        [
          "ssid": network.ssid ?? "",
          "rssi": Int(network.rssiValue),
        ]
      }
      DispatchQueue.main.async { result(rows) }
    } catch {
      DispatchQueue.main.async {
        result(FlutterError(code: "location_denied", message: "\(error)", details: nil))
      }
    }
  }

  // MARK: - Join

  static func join(client: CWWiFiClient, ssid: String, password: String?) -> Bool {
    guard !ssid.isEmpty else { return false }
    // Path 1: CoreWLAN associate. Needs the CWNetwork object, i.e. a
    // scan, i.e. location authorization; skip silently when unavailable.
    if let iface = client.interface(),
       let ssidData = ssid.data(using: .utf8),
       let networks = try? iface.scanForNetworks(withSSID: ssidData),
       let network = networks.first(where: { $0.ssid == ssid }) {
      do {
        // associate(to:password:) is void and throws on failure; success
        // means the association command was accepted.
        try iface.associate(
          to: network, password: (password?.isEmpty == false) ? password : nil)
        return true
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
    var blocks = out.components(separatedBy: "\n\n").map { block -> (String, String)? in
      var service = ""
      var device = ""
      for line in block.components(separatedBy: "\n") {
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
    let pick = blocks.first(where: { $0.1.hasPrefix("en") }) ?? blocks[0]
    return pick
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

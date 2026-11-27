import Cocoa
import CoreLocation
import CoreWLAN
import FlutterMacOS
import os

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ sender: NSApplication) -> Bool {
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
///   Location Services authorization, so `networksetup -getairportnetwork`
///   (a system tool, not location-gated) is the fallback.
/// - `scan` -> [{ssid, rssi(dBm)}] — gated on Location Services (see
///   `MacLocationGate`): `location_denied` once the user refused,
///   `location_pending` until the prompt is answered, `scan_failed` for a
///   CoreWLAN error. Only networks that expose an SSID are returned.
/// - `join` {ssid, password?} -> Bool — CoreWLAN associate when the SSID
///   is scannable, else `networksetup -setairportnetwork`.
/// - `disconnect` -> Bool.
/// - `adapterState` -> {present: Bool, powerOn: Bool} — whether a WLAN
///   interface exists and whether its radio is on. Reads no SSIDs, so it
///   needs no Location Services (the self-check calls it on every probe).
/// - `locationStatus` -> String — the `MacLocationGate.Status` raw value.
///   Reads the authorization verdict only; never prompts.
///
/// CoreWLAN calls and the networksetup subprocess are slow (seconds), so
/// they run off the main thread; results hop back to main. The location
/// gate is the exception: CLLocationManager belongs to the thread that
/// created it (main here), which is also where the handler runs.
enum MacWlanChannel {
  static let name = "neolinker/mac_wlan"
  private static let networksetup = "/usr/sbin/networksetup"
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "NeoLinker", category: "mac_wlan")

  static func attach(to controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: name, binaryMessenger: controller.engine.binaryMessenger)
    let location = MacLocationGate()
    channel.setMethodCallHandler { call, result in
      let client = CWWiFiClient.shared()
      switch call.method {
      case "currentSsid":
        DispatchQueue.global(qos: .userInitiated).async {
          let ssid = currentSsid(client: client)
          DispatchQueue.main.async { result(ssid) }
        }
      case "scan":
        handleScan(client: client, location: location, result: result)
      case "join":
        let args = call.arguments as? [String: Any]
        let ssid = args?["ssid"] as? String ?? ""
        let password = args?["password"] as? String
        // Read the gate here: it lives on this (main) thread.
        let locationAuthorized = location.status == .authorized
        DispatchQueue.global(qos: .userInitiated).async {
          let ok = join(
            client: client, ssid: ssid, password: password,
            locationAuthorized: locationAuthorized)
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
      case "locationStatus":
        // Verdict only: unlike `scan` this never prompts.
        result(location.status.rawValue)
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

  /// Location gate first, on the gate's own thread: a closed gate must
  /// neither reach CoreWLAN nor look like an empty scan.
  static func handleScan(
    client: CWWiFiClient, location: MacLocationGate,
    result: @escaping FlutterResult
  ) {
    switch location.status {
    case .authorized:
      break
    case .denied:
      logger.error("scan skipped: Location Services authorization denied")
      result(FlutterError(
        code: "location_denied",
        message: "Location Services authorization denied", details: nil))
      return
    case .pending, .notRequested:
      // The prompt is the user's to answer; the next poll re-checks.
      location.requestIfNeeded()
      result(FlutterError(
        code: "location_pending",
        message: "waiting for Location Services authorization", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      scan(client: client, result: result)
    }
  }

  static func scan(client: CWWiFiClient, result: @escaping FlutterResult) {
    guard let iface = client.interface() else {
      DispatchQueue.main.async {
        result(FlutterError(code: "no_interface", message: "no Wi-Fi interface", details: nil))
      }
      return
    }
    let networks: Set<CWNetwork>
    do {
      networks = try iface.scanForNetworks(withSSID: nil)
    } catch {
      logger.error("scan failed: \(error.localizedDescription, privacy: .public)")
      DispatchQueue.main.async {
        result(FlutterError(code: "scan_failed", message: "\(error)", details: nil))
      }
      return
    }
    // Networks without an SSID — hidden ones, or every one of them while
    // the location gate is closed — are not device APs.
    let rows: [[String: Any]] = networks.compactMap { network in
      guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
      return ["ssid": ssid, "rssi": Int(network.rssiValue)]
    }
    DispatchQueue.main.async { result(rows) }
  }

  // MARK: - Join

  static func join(
    client: CWWiFiClient, ssid: String, password: String?,
    locationAuthorized: Bool
  ) -> Bool {
    guard !ssid.isEmpty else { return false }
    // Path 1: CoreWLAN associate. Needs the CWNetwork object, i.e. a scan,
    // i.e. the location gate open; skipped while it is closed.
    if locationAuthorized,
       let iface = client.interface(),
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

/// Location Services gate in front of CoreWLAN's SSID visibility. macOS
/// 10.15+ exposes Wi-Fi SSIDs only to apps authorized for Location
/// Services; anything else gets networks whose `ssid` is nil, without an
/// error. Inside the App Sandbox the location daemon is reachable only
/// with the `com.apple.security.location` entitlement.
///
/// Main-thread only: CLLocationManager must be used from the thread that
/// created it, and the method-call handler (its sole client) runs there.
final class MacLocationGate: NSObject, CLLocationManagerDelegate {
  enum Status: String {
    case authorized
    /// Refused, restricted by policy, or Location Services switched off
    /// system-wide — all fixed in System Settings, never by prompting.
    case denied
    /// Not decided yet, and the prompt was already requested this launch.
    case pending
    /// Not decided yet; never asked.
    case notRequested
  }

  private let manager = CLLocationManager()
  private var prompted = false

  override init() {
    super.init()
    manager.delegate = self
  }

  var status: Status {
    switch manager.authorizationStatus {
    case .authorized, .authorizedAlways:
      return .authorized
    case .denied, .restricted:
      return .denied
    case .notDetermined:
      return prompted ? .pending : .notRequested
    @unknown default:
      return .denied
    }
  }

  /// Requests when-in-use authorization. The system prompts at most once
  /// per app identity; a decided status makes later calls no-ops.
  func requestIfNeeded() {
    guard status == .notRequested else { return }
    prompted = true
    manager.requestWhenInUseAuthorization()
  }
}

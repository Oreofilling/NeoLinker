/// TCP reachability probe for LAN console devices (NE503): a multicast
/// beacon only proves the device spoke at some point — the console needs
/// a working unicast TCP/443 route, which multi-NIC/VPN routing can break
/// while discovery still sees the announcements. Injectable so widget
/// tests never open sockets (same pattern as [openWifiSettings]).
library;

import 'dart:io';

/// Returns whether [host]:[port] accepts a TCP connection in time.
typedef HostProbe = Future<bool> Function(String host, int port);

/// Connects, drops the socket immediately (no bytes are spoken) and
/// reports success. Any failure — refused, unroutable, timeout — is just
/// false; the console dialog's retry owns the next attempt.
Future<bool> probeHostPort(String host, int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(milliseconds: 1500),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

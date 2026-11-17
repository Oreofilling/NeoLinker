/// CT-Disc discovery source: joins the announcement multicast group on
/// the allowed NICs, turns ct-announce datagrams into candidates
/// (product flow 5.3), and solicits with ct-probe (CT_DISC_PROTOCOL
/// v1.2.0 §3.3).
///
/// Announces beacon every 5 s on their own; the ct-probe solicitation
/// makes a device answer immediately instead of waiting for its next
/// beacon, which is what keeps a fresh scan short. NE503's device side
/// does not answer probes yet (its listener only handles ct-announce
/// and ct-set-network), so the send is forward-compatible rather than
/// load-bearing today. The candidate id encodes the receiving interface
/// so a device answering on two subnets stays visible on both (5.3:
/// same response on different NICs is displayed separately); the
/// registry still merges by MAC suffix across channels.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:discovery_domain/discovery_domain.dart';

import 'ct_announce.dart';
import 'nic_classifier.dart';

/// Multicast group announced by NE301 firmware (ct_discover.h).
const String kCtDiscMulticastGroup = '239.255.255.250';

/// Announcement port (ct_discover.h).
const int kCtDiscPort = 19850;

/// IPPROTO_IP / SOL_IP for the IPv4 membership socket option (identical
/// value 0 on Linux, Windows and macOS).
const int kIpProtoIpLevel = 0;

/// IP_ADD_MEMBERSHIP under BSD numbering (ws2ipdef.h on Windows,
/// netinet/in.h on macOS).
const int kIpAddMembershipBsd = 12;

/// IP_ADD_MEMBERSHIP under Linux (uapi/linux/in.h).
const int kIpAddMembershipLinux = 35;

/// Resolves the IP_ADD_MEMBERSHIP option number for [operatingSystem].
///
/// The option name is portable but the number is not: hardcoding one
/// platform's value fails setsockopt on the others (Windows answers
/// WSAENOPROTOOPT 10042), and a swallowed per-NIC failure turns that
/// into a silently dead channel.
int ipAddMembershipFor(String operatingSystem) =>
    operatingSystem == 'linux' ? kIpAddMembershipLinux : kIpAddMembershipBsd;

/// Client solicitation payload (CT-Disc v1.2.0 §3.3): a device that
/// receives it answers with an immediate ct-announce instead of
/// waiting for its next beacon interval.
const String kCtProbePayload = '{"type":"ct-probe"}';

/// IP_MULTICAST_IF option number (in_addr payload). Unlike membership
/// numbering this value is 2 on Linux, Windows and macOS alike.
const int kIpMulticastIfOption = 2;

/// Channel liveness timeout (CT-Disc v1.2.0 §5): a discovered row stays
/// listed this long after the last ct-announce on its ct-disc leg.
const Duration kCtDiscChannelTimeout = Duration(seconds: 30);

/// Sends one ct-probe per joined NIC, pinning the multicast egress
/// interface before each send — without IP_MULTICAST_IF every probe
/// would leave through the default route and subnets behind the other
/// NICs would never hear the solicitation. A NIC that refuses the
/// option or the send is skipped, not fatal for the rest.
Future<void> sendCtProbe(
  RawDatagramSocket socket,
  List<NicEndpoint> joinedInterfaces,
) async {
  final group = InternetAddress(kCtDiscMulticastGroup);
  final payload = Uint8List.fromList(utf8.encode(kCtProbePayload));
  final sent = <String>{};
  for (final nic in joinedInterfaces) {
    if (!sent.add(nic.interfaceName)) continue; // one send per interface
    try {
      socket.setRawOption(RawSocketOption(
        kIpProtoIpLevel,
        kIpMulticastIfOption,
        Uint8List.fromList(nic.address.rawAddress.take(4).toList()),
      ));
      socket.send(payload, group, kCtDiscPort);
    } catch (_) {
      // One unsendable NIC must not abort the sweep across the rest.
    }
  }
}

/// Sources whose channel supports active solicitation implement this;
/// the scan loop re-fires the solicitation at every scan start. It is a
/// subtype of [DiscoverySource] (a solicitable source is a discovery
/// source), which also keeps Dart's `is` promotion working at fan-out
/// call sites.
abstract interface class ProbeCapableDiscoverySource
    implements DiscoverySource {
  /// Re-sends the channel solicitation on a live channel; no-op while
  /// the channel is stopped.
  Future<void> sendProbe();
}

/// Normalizes one observation into a candidate.
///
/// The announce carries no busy flag, so busy=false / provisionable=true
/// — the session attempt is the arbiter, same as the AP channel.
DiscoveryCandidate ctDiscCandidateFromObservation(
  CtDiscObservation observation, {
  required String interfaceName,
  DateTime Function()? now,
}) {
  final seen = (now ?? DateTime.now)();
  return DiscoveryCandidate(
    candidateId: 'ctdisc:${observation.macSuffix}@$interfaceName',
    macSuffix: observation.macSuffix,
    modelHint: observation.product,
    channels: const {DiscoveryChannel.ctDisc},
    provisionable: true,
    busy: false,
    lastSeen: seen,
    // Feeds the per-channel TTL sweep: this leg stays listed for
    // kCtDiscChannelTimeout even while the faster channels expire.
    lastSeenByChannel: {DiscoveryChannel.ctDisc: seen},
  );
}

/// Multicast listener source.
final class CtDiscDiscoverySource
    implements DiscoverySource, ProbeCapableDiscoverySource {
  CtDiscDiscoverySource({
    Future<List<NicEndpoint>> Function({bool includeVirtual})? nicEnumerator,
    Future<RawDatagramSocket> Function(List<String> nicNames)? socketFactory,
    Future<void> Function(
      RawDatagramSocket socket,
      List<NicEndpoint> joinedNics,
    )? probeSender,
    bool includeVirtualNics = false,
    DateTime Function()? now,
  })  : _nicEnumerator = nicEnumerator ?? enumerateNicEndpoints,
        _socketFactory = socketFactory,
        _probeSender = probeSender,
        _includeVirtual = includeVirtualNics,
        _now = now;

  final Future<List<NicEndpoint>> Function({bool includeVirtual})
      _nicEnumerator;
  final Future<RawDatagramSocket> Function(List<String> nicNames)?
      _socketFactory;
  final Future<void> Function(
    RawDatagramSocket socket,
    List<NicEndpoint> joinedNics,
  )? _probeSender;
  final bool _includeVirtual;
  final DateTime Function()? _now;

  final _candidates = StreamController<DiscoveryCandidate>.broadcast();
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  bool _starting = false;

  /// NICs currently joined (diagnostics + NIC picker state).
  List<NicEndpoint> joinedNics = const <NicEndpoint>[];

  /// Full endpoint pool used for source attribution; unlike [joinedNics]
  /// it keeps every address, so a multi-address NIC still labels
  /// announcements from any of its subnets.
  List<NicEndpoint> _attributionNics = const <NicEndpoint>[];

  @override
  Stream<DiscoveryCandidate> get candidates => _candidates.stream;

  @override
  Future<void> start() async {
    if (_socket != null || _starting) return;
    _starting = true;
    try {
      final nics = await _nicEnumerator(includeVirtual: _includeVirtual);
      final socket = await (_socketFactory?.call(
            nics.map((nic) => nic.interfaceName).toList(),
          ) ??
          _bindMulticast(nics));
      _socket = socket;
      _attributionNics = nics;
      // Factory-injected sockets bypass _bindMulticast's bookkeeping;
      // there the injected pool is the join seam, so report it as-is.
      if (_socketFactory != null) joinedNics = nics;
      _socketSub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final observation = parseCtAnnounce(datagram.data);
        if (observation == null) return;
        _candidates.add(
          ctDiscCandidateFromObservation(
            observation,
            interfaceName: _interfaceFor(datagram),
            now: _now,
          ),
        );
      });
      // Solicit once per fresh start (§3.3): devices answer with an
      // immediate announce instead of waiting out their beacon interval.
      // Isolated so a refusing socket never tears down the listener.
      try {
        await (_probeSender ?? sendCtProbe)(socket, joinedNics);
      } catch (_) {
        // Probe is an accelerator, never a precondition.
      }
    } catch (_) {
      // Bind failures (no NIC, sockets unavailable) leave the channel
      // silent; capability UI comes from the environment probe.
      _socket = null;
      joinedNics = const <NicEndpoint>[];
      _attributionNics = const <NicEndpoint>[];
    } finally {
      _starting = false;
    }
  }

  @override
  Future<void> stop() async {
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    joinedNics = const <NicEndpoint>[];
    _attributionNics = const <NicEndpoint>[];
  }

  @override
  Future<void> sendProbe() async {
    final socket = _socket;
    if (socket == null) return; // channel down: silent no-op
    try {
      await (_probeSender ?? sendCtProbe)(socket, joinedNics);
    } catch (_) {
      // Same posture as the start-time probe: never fatal.
    }
  }

  /// Binds once and joins the group through every selected NIC.
  ///
  /// One membership per interface: a NIC holding several unicast
  /// addresses (secondary IPs) still gets a single join — a second
  /// membership for the same group and interface is redundant and
  /// Windows rejects it. [joinedNics] ends up holding only the NICs
  /// whose membership really took, so diagnostics never claim a join
  /// that setsockopt rejected.
  Future<RawDatagramSocket> _bindMulticast(List<NicEndpoint> nics) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kCtDiscPort,
      reuseAddress: true,
    );
    final group = InternetAddress(kCtDiscMulticastGroup);
    final joined = <NicEndpoint>[];
    final joinedInterfaces = <String>{};
    for (final endpoint in nics) {
      if (!joinedInterfaces.add(endpoint.interfaceName)) continue;
      try {
        _joinGroup(socket, group, endpoint.address);
        joined.add(endpoint);
      } catch (_) {
        // One unjoinable NIC (some VPN adapters refuse) must not take
        // down the whole channel; the rest keep listening.
      }
    }
    joinedNics = joined;
    return socket;
  }

  // Dart removed RawDatagramSocket.joinMulticastGroup; membership goes
  // through the raw IP_ADD_MEMBERSHIP socket option instead. The level
  // (IPPROTO_IP = 0) is portable, but the option NUMBER is not — see
  // ipAddMembershipFor. The payload is the 8-byte ip_mreq
  // {group, interface address}.
  static void _joinGroup(
    RawDatagramSocket socket,
    InternetAddress group,
    InternetAddress nicAddress,
  ) {
    final mreq = Uint8List(8)
      ..setAll(0, group.rawAddress.take(4).toList())
      ..setAll(4, nicAddress.rawAddress.take(4).toList());
    socket.setRawOption(
      RawSocketOption(
        kIpProtoIpLevel,
        ipAddMembershipFor(Platform.operatingSystem),
        mreq,
      ),
    );
  }

  /// Best-effort NIC attribution: prefer the joined NIC whose /24
  /// contains the datagram source, else the source address itself
  /// (diagnostics only — the candidate id stays stable per interface).
  String _interfaceFor(Datagram datagram) {
    for (final nic in _attributionNics) {
      if (_sameSubnet(nic.address, datagram.address)) {
        return nic.interfaceName;
      }
    }
    return datagram.address.address;
  }

  static bool _sameSubnet(InternetAddress nic, InternetAddress source) {
    final nicRaw = nic.rawAddress;
    final srcRaw = source.rawAddress;
    if (nicRaw.length != 4 || srcRaw.length != 4) return false;
    // /24 assumption is fine for attribution display: exactness is not
    // required, only a stable label.
    return nicRaw[0] == srcRaw[0] &&
        nicRaw[1] == srcRaw[1] &&
        nicRaw[2] == srcRaw[2];
  }
}

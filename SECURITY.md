# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 0.2.x   | ✅        |

Only tagged releases are supported. CI build artifacts from `main` are
development snapshots.

## Reporting a vulnerability

**Please do not report security vulnerabilities in public issues.**

Use GitHub's *private vulnerability reporting* on this repository
(**Security → Report a vulnerability**), which notifies the maintainers
privately and lets us coordinate a fix and disclosure. If that channel is
unavailable to you, contact the maintainers via the GitHub profile linked
on the [repository page](https://github.com/camthink-ai/NeoLinker).

Please include: affected component (app / package name), app version
(shown in the sidebar footer), Windows version, steps or proof of concept,
and impact assessment. We aim to acknowledge reports within a few business
days.

Reports about CamThink device firmware are also welcome through the same
channel; we will route them to the firmware team.

## Scope

In scope: the NeoLinker desktop app and all packages in this repository
(`apps/desktop_app` + `packages/*`).

## Known security considerations

These are design properties of the provisioning protocol v1 — documented
here so operators can make informed choices, not bugs:

- **SoftAP transport is plaintext HTTP.** While provisioning over a
  device's softAP, traffic (including Wi-Fi credentials) is unencrypted on
  that access point. Provision devices in a controlled environment.
- **BLE pairing is Just Works.** The BLE link is encrypted after pairing,
  but Just Works does not authenticate the device during the pairing
  exchange, so an active on-path attacker present at first pairing is not
  detectable by the protocol. The exposure window is the short
  configuration session (devices leave configuration mode automatically
  when idle).
- **Receipts and history exports are plain text.** They contain device
  identity and configuration summaries — review them before sharing.
- Encrypted transports (e.g. TLS on the NE503 management interface) are
  initiated by the device side with self-signed certificates; the app does
  not add its own certificate validation on top.

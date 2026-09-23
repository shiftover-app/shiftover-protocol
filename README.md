# ShiftoverProtocol

The wire vocabulary shared by the three halves of Shiftover's remote access:

| Consumer | Language | License |
|---|---|---|
| **Shiftover** (macOS desktop) | Swift | AGPL-3.0 |
| **Shiftover Go** (iOS) | Swift | closed |
| **Shiftover Cloud** (Worker + Durable Object) | TypeScript — mirrors these shapes | closed |

**MIT licensed, zero dependencies.** Both are deliberate:

- **MIT** so the AGPL desktop cannot make the closed iOS app a derivative work
  (GPL-family licensing also has a contentious App Store history).
- **Zero dependencies** so consuming it from iOS does not drag in the desktop's
  macOS-only graph (Sparkle in particular). Please keep it that way.

## Shape

One WebSocket message is one frame. There is no length prefix — the message
boundary *is* the frame boundary.

```
[1 byte: FrameType][payload]
```

| Tag | Frame | Payload |
|---|---|---|
| `0x01` / `0x02` | `hello` / `helloAck` | JSON — cleartext `protocolVersion` + one Noise IK handshake message |
| `0x10` / `0x11` | `request` / `response` | JSON — `RPCRequest` / `RPCResponse`, correlated by `id` |
| `0x12` | `event` | JSON — `ServerEvent`, desktop→phone push |
| `0x20` / `0x21` | `terminalData` / `terminalInput` | `[16B paneID][raw bytes]` |

Terminal traffic stays **raw** rather than base64-in-JSON: it is the
highest-volume payload on the channel by an order of magnitude, and base64 would
inflate it ~33% on a metered cellular link. Overhead is a fixed 16 bytes.

## Security

Every connection — LAN or relay — opens with a
[Noise](https://noiseprotocol.org/noise.html) handshake,
**`Noise_IK_25519_ChaChaPoly_SHA256`**, with the phone as initiator (it knows the
Mac's static key from the pairing QR). `Noise.swift` is checked byte for byte
against the published cacophony test vector for that protocol name.

- **Only `protocolVersion` is in the clear**, so an out-of-range peer can still be
  told which side to update. It is bound into the Noise prologue, so editing it in
  flight fails the handshake.
- **Identity is sealed.** Device name, device id, app versions, both long-term
  keys and the Mac's host name ride inside the handshake payloads — invisible to
  the LAN and to the relay.
- **Forward secrecy.** Session keys depend on ephemeral keys discarded after the
  handshake.
- **Replay-proof frames.** Transport nonces are implicit counters; a frame opens
  only once, at the position it was sealed for.
- **Pairing** proves the QR's one-time secret with an HMAC over the handshake
  hash (`RemotePairing.pairingProof`), so a proof cannot be lifted into another
  handshake.

The transport underneath (`ws://` on the LAN, `wss://` to the relay) adds nothing
the channel relies on.

## Compatibility rules

The three components ship through three independent release channels — Sparkle,
the App Store, and instant Worker deploys — so they will **permanently** be at
different versions in the wild. The protocol detects that rather than failing
mysteriously:

1. `Hello` carries `protocolVersion`; both ends run `ProtocolVersion.check(peerVersion:)`.
2. A refusal names **which side** to update. `VersionCompatibility.refusalMessage(localSideIsPhone:)`.
3. **Unknown frame types decode to `nil` and must be SKIPPED, not treated as an error.**
4. **Unknown capabilities degrade to `.unknown`** rather than failing the handshake.
5. Unknown RPC methods must answer `.failure(.unsupportedMethod)` — never drop the connection.
6. Within a major version, changes are **additive only**.

Rules 3–5 are what let a newer peer introduce something without breaking every
older build; each is covered by a test.

## Not on the wire

Domain types (`Project`, `Worktree`, `Pane`) are **mirrored as DTOs, never
shared**. They carry persistence semantics, filesystem URLs and migration
history that have no business on a phone — and the separation means a
`PersistedState` schema bump can never force an App Store release.

If Go does not render or act on a field, it does not belong here.

## Tests

```sh
swift test
```

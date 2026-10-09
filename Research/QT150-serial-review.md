# QT100/150 serial review — 2026-09-08

## Sources inspected

- [JQuickTake Camera.java](https://github.com/Crazylegstoo/JQuickTake/blob/94ba376387a385e2a092c779733dbdcd4571405b/src/main/java/com/crazylegs/JQuickTake/Camera.java),
  pinned to revision `94ba376387a385e2a092c779733dbdcd4571405b`.
- [Colin Leroy-Mira's QT100/150 protocol reference](https://www.colino.net/wordpress/en/archives/2023/10/29/the-apple-quicktake-100-150-serial-communication-protocol/),
  also linked by JQuickTake's README.
- SwiftTake's existing commands, session and local QT150 trace from September 5.

JQuickTake's source was inspected outside the repository as a behavioural
reference; no Java implementation was copied into the app.

## Findings from the references

JQuickTake's `pingCamera` checks for the camera's `0x00` response. Its reader
accumulates bytes, and `openCamera` uses wake byte 3 (`0xC8`) for QT150 identity.
Its speed sequence agrees with SwiftTake's existing command bytes and delays.
Its reader can wait indefinitely, so it is not itself a timeout/recovery design
to reproduce.

Colin's reference identifies `0x02` as command rejection and `0x06` as the
host acknowledgement. It describes a seven-byte wake, ten-byte open reply,
9600 8N1 startup followed by even parity, and 512-byte image blocks. It recommends
discarding speed-change filler until quiet and no acknowledgement after the
final data block. It supplies the same no-op ping command used by JQuickTake.

These establish protocol facts, not a guarantee about adapter behaviour on this
Mac. In particular, neither source establishes a universal recovery sequence
for an already-awake QT150 stranded mid-transfer at a different baud.

## Decisions implemented

- Read the wake one byte at a time under one six-second deadline. A bounded
  scanner finds the header despite leading chatter and preserves partial input.
  This retains the old approximate overall wake budget, not JQuickTake's
  indefinite read loop.
- Clear wake identity on open, handshake and disconnect. The manager's existing
  remembered-model fallback is unchanged.
- Require a complete open reply and `0x00` status for ping, speed negotiation,
  final handshake acknowledgement and commands. Stop on failed reconfiguration.
- Use the documented ping for liveness instead of a transfer acknowledgement.
- Give complete QT100/150 command/reply transactions FIFO ownership across
  suspension points. Queued cancelled commands release ownership without
  sending; disconnect is ordered after in-flight work.
- Preserve command payloads, existing speed options, block sizes and final-block
  acknowledgement behaviour. Keep the passive Kodak-first/Fuji-second Connect
  routing and the QT200 session unchanged.

## Scope of the evidence

These references establish protocol behavior, not every adapter's recovery
sequence. Current job ownership and I/O bounds are described in
[serial reliability](../Docs/QT150-RELIABILITY.md). Scripted checks establish
host-side parsing and ordering; hardware checks remain separate.

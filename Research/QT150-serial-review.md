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

## September 9 hardware regression

The 23:01 QT150 trace from the FTDI adapter shows an aligned wake burst and a
complete open reply, followed by a successful ping and speed command. The quiet
interval drain removed zero bytes, but the final speed-change ACK read `0xAA`.
The new strict status check rejected that filler, ending a live handshake. The
next attempt was silent at 9600; the camera may have remained at the negotiated
57600 rate.

Both references above describe `0xAA` speed-change filler before the final
`0x00` reply. The final speed-change exchange must tolerate delayed filler while
still requiring success. This exception belongs only to that exchange; ordinary
command replies must continue rejecting `0xAA`. A fresh power cycle is needed for
the first hardware retry. Scripted success alone cannot confirm this regression
is resolved on the adapter.

A direct hardware test with the attached QT150 showed why ignoring late filler
alone was insufficient: after an early ACK, all 1024 filler bytes arrived but no
success status followed. Increasing the pre-ACK quiet interval from 200 to
500 ms (still bounded by five seconds) drained all 1024 bytes before the ACK.
The camera then returned `0x00`, a full 128-byte device-info response and a
successful liveness ping at 57600 baud. The final ACK reader also tolerates
residual `0xAA` under one two-second deadline and a 1024-byte cap; it never
accepts filler as success or resends the ACK. Other commands remain strict.

This test used a different FTDI adapter from the initial failure trace. It establishes operation on the attached setup, not every
adapter, baud rate or camera family. No photos were captured or deleted and no
camera settings were changed.

The rebuilt Release app also passed the shared Connect-button path, identified
QT150, read the 13-photo count and populated the thumbnail gallery. A subsequent
Disconnect → Connect with the camera left powered on connected again. The
Desktop app was disconnected first to release its exclusive serial-port handle;
the successful app test used the reviewed Release build, not that Desktop copy.
Full-photo import, interrupted transfer, 9600 baud and QT100/QT200 remain untested
in this hardware session.

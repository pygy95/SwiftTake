# Serial reliability

The shared Connect path probes the Kodak QT100/150 family before the Fuji QT200
family. Protocol sources are recorded in the [serial review](../Research/QT150-serial-review.md).

## Connection and transaction handling

- A bounded wake scanner preserves partial input and discards leading chatter.
- Open replies must be complete; command success requires the expected status.
- Complete exchanges retain FIFO ownership across suspension points. Queued,
  cancelled commands release ownership without sending.
- Serial reads and writes use monotonic deadlines and nonblocking I/O. Failed
  partial writes close the port. Descriptor generations protect reopened ports.
- Kodak speed negotiation waits for 500 ms of quiet before the final ACK and
  accepts bounded residual `0xAA` filler while still requiring `0x00` success.
- Fuji compound operations share transaction ownership. Reply lengths, framing
  and checksums are validated; a missing ACK does not blindly repeat a control
  command that may already have acted.
- Camera jobs belong to connection generations. Old results cannot populate a
  new session, and reconnect waits for teardown.

## Erase

QT100/150 erase holds the transaction while waiting up to 45 seconds for the
reply. Explicit refusal and an unconfirmed outcome are distinct. If completion
is unconfirmed, framing is re-established before metadata is read. The manager
polls the photo count without repeating erase, invalidates slot-based caches,
and rejects zero-capacity Kodak metadata. Success requires a confirmed empty
camera. QT200 serial erase is not exposed.

## Evidence and limits

QT150 hardware checks have covered connection at 57600 baud, powered-on
reconnection, thumbnails, single and batch imports, and opening saved 640×480
images. User testing also reported successful offline QTK conversion,
interrupted-transfer recovery and the corrected erase flow.

These results apply to the tested QT150/FTDI setup. They do not establish all
adapter, baud-rate or camera combinations. The software harness covers both
protocol families, with more Kodak cases than Fuji cases.

Mid-transfer Kodak recovery still needs wire-level verification: an already-awake
fallback during initial Connect does not establish resynchronisation at every
possible interrupted-transfer state. Use fresh traces before changing command
bytes or timings. Follow the [camera acceptance checks](CAMERA-ACCEPTANCE.md)
for further hardware testing.

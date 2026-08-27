#!/usr/bin/env python3
"""Drive the bring-up steps in spec B.5 from a PC.

    python gem_host.py monitor  --port COM4
    python gem_host.py rx       --port COM4 --iface Ethernet --count 100
    python gem_host.py echo     --port COM4 --iface Ethernet --count 100
    python gem_host.py corrupt  --port COM4 --iface Ethernet
    python gem_host.py soak     --port COM4 --iface Ethernet --hours 4

Each subcommand is one step of B.5, and each prints what it observed rather than
only whether it was happy, because at bring-up the interesting output is the
number that was wrong rather than the word FAIL.

WHAT THIS NEEDS
  * a serial port on the board's USB-UART (CP2102GM), 115200 8N1
  * raw Ethernet send/receive: Scapy, plus Npcap on Windows or root on Linux
  * `pip install -r requirements.txt`

Both are imported lazily, one command at a time, so that `monitor` works on a
machine with no Scapy and the parser's tests run on a machine with neither.

ONE LIMITATION, STATED HERE BECAUSE IT CHANGES WHAT B.5 STEP 7 CAN MEAN.
A commodity NIC will not transmit a frame with a bad FCS, and will not transmit
a runt: the FCS is computed in hardware after the driver hands the frame over,
and frames shorter than 60 octets are padded there too. Neither is a Scapy
limitation to be worked around with a flag -- the bits never reach the wire.

So of R10's four receive error classes, this harness can provoke exactly one
from a PC: oversize. Bad FCS, runt and RX_ER need something that owns its own
transmitter -- a second FPGA, a traffic generator, or a NIC whose driver exposes
CRC offload controls (rare, and worth checking before assuming). The `corrupt`
command does what it can and says plainly what it could not do, rather than
sending something the NIC quietly fixed and reporting a pass. All four classes
are covered bit-exactly in simulation against the golden model; what hardware
adds is confidence in the PHY and the pins, and one class exercises those as
well as four would.

A SECOND LIMITATION, WHICH CHANGES WHAT STEP 4 CAN MEAN ON A LIVE SEGMENT.
The board counts every frame that reaches it regardless of destination address
-- filtering is R12, a stated non-goal, and the receive path is promiscuous
(B.7) -- so `rx_ok` advances on the segment's own traffic as well as on this
command's. `rx` therefore opens with a control window that sends nothing,
measures that rate, and checks `rx_ok` against an interval rather than a single
number. On a quiet link the measured rate is zero and the check is the exact
equality it has always been; on a busy one it resolves a drop only if the
shortfall is larger than what the ambient rate accounts for, and prints that
figure so the run says what it proved. See `ambient_allowance`.
"""

from __future__ import annotations

import argparse
import math
import os
import random
import sys
import time
from dataclasses import dataclass
from typing import Iterable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gem_records as gr

# IEEE 802 reserves 0x88B5 and 0x88B6 for local experimental use, which is
# exactly what this is. Anything routable would risk a switch or a stack
# deciding it knew better than the test.
ETHERTYPE = 0x88B5

# Locally administered address standing in for the board. Nothing in the design
# filters on it -- R12 is a stated non-goal and the receive path is promiscuous
# (B.7) -- so this is a label for the human reading a capture, not a filter.
BOARD_MAC = "02:00:00:00:00:01"

# What gem_echo returns: the frame it received, minus preamble, SFD and FCS,
# with DA and SA exchanged. The payload includes whatever pad the sender's NIC
# added, because B.4a's delivery contract does not strip pad -- there is no
# length field to strip against when Length/Type is a Type.
MIN_PAYLOAD_ON_WIRE = 46


# --------------------------------------------------------------------------
# Serial
# --------------------------------------------------------------------------
class StatusPort:
    """The board's status readout, one record at a time."""

    def __init__(self, port: str, baud: int = 115200, timeout: float = 3.0):
        try:
            import serial  # noqa: PLC0415  (lazy on purpose, see the header)
        except ImportError:
            sys.exit("pyserial is not installed: pip install -r requirements.txt")
        self._ser = serial.Serial(port, baud, timeout=timeout)
        # The first line is very likely a partial record, since the port was
        # opened part way through one. Reading and discarding it here means the
        # caller never has to think about it.
        self._ser.readline()

    def read_record(self, tries: int = 4) -> gr.Record:
        lines = (self._ser.readline().decode("ascii", errors="replace")
                 for _ in range(tries))
        return _read_record_from_lines(lines, tries)

    def close(self) -> None:
        self._ser.close()


def _read_record_from_lines(lines: Iterable[str], tries: int) -> gr.Record:
    """The retry/skip decision `read_record` makes, isolated from the port.

    Blank lines (the readline timeout firing) and torn lines (the port opened
    mid-record) are expected and skipped; anything else exhausting `tries`
    means the board is not talking, not that this host got unlucky.
    """
    seen = 0
    for line in lines:
        seen += 1
        if seen > tries:
            break
        if not line.strip():
            continue
        try:
            return gr.parse(line)
        except gr.RecordError:
            continue
    raise TimeoutError(
        "no complete status record arrived. The board prints one a second: "
        "check the port, the baud (115200 8N1), and that the design is out "
        "of reset -- the lock LED tells you the last of those")


# --------------------------------------------------------------------------
# Frames
# --------------------------------------------------------------------------
def _scapy():
    try:
        from scapy.all import Ether, Raw, sendp, sniff, conf  # noqa: PLC0415
    except ImportError:
        sys.exit("scapy is not installed: pip install -r requirements.txt")
    return Ether, Raw, sendp, sniff, conf


@dataclass
class EchoResult:
    sent: int = 0
    returned: int = 0
    mismatched: int = 0
    bad_swap: int = 0


def _payload(n: int, seed_byte: int) -> bytes:
    return bytes(((seed_byte + i) & 0xFF) for i in range(n))


def _expected_reply_payload(sent: bytes) -> bytes:
    """What the board should send back for a given payload.

    The NIC pads anything short of 46 octets before it reaches the wire, and
    gem_echo returns the pad along with the payload, so the reply is the sent
    payload zero-extended to the minimum. Comparing without allowing for that
    reports every small frame as corrupted.
    """
    if len(sent) >= MIN_PAYLOAD_ON_WIRE:
        return sent
    return sent + bytes(MIN_PAYLOAD_ON_WIRE - len(sent))


# --------------------------------------------------------------------------
# B.5 step 4 -- receive only, counters
# --------------------------------------------------------------------------
def ambient_allowance(control_frames: int, control_records: int,
                      test_records: int) -> int:
    """How many frames the segment itself may add to `rx_ok` during the test.

    `control_frames` is what `rx_ok` advanced by over `control_records` of the
    board's one-a-second status records with nothing being sent. This scales
    that rate to a window of `test_records` records and adds three standard
    deviations of a Poisson process at the same rate, since the count in a
    window varies about its mean by roughly the square root of it. Three sigma
    rather than one because a false FAIL at bring-up costs an operator a re-run
    and some doubt about a receive path that is fine, and what the extra width
    costs is stated in `evaluate_rx` rather than hidden.

    Zero in, zero out, deliberately. A control window that saw no ambient
    traffic leaves the check exactly as strict as it was before this function
    existed: `rx_ok` must equal the count sent. The allowance is never wider
    than the measured noise makes it, which is the whole reason for measuring
    rather than picking a tolerance.

    It bounds a rate, though; it does not identify frames. Bursty ambient
    traffic -- a burst of mDNS that missed the control window entirely -- can
    still exceed it. That shows up as a FAIL with a small excess on a run whose
    control window was quiet, and is worth re-running before it is read as a
    defect.
    """
    if control_frames <= 0 or control_records <= 0 or test_records <= 0:
        return 0
    mean = control_frames * test_records / control_records
    return math.ceil(mean + 3.0 * math.sqrt(mean))


def evaluate_rx(d: dict[str, int], expected_count: int,
                allowance: int = 0) -> tuple[bool, list[str]]:
    """Did `expected_count` good frames arrive and nothing else move.

    `rx_ok` has to land in `[expected_count, expected_count + allowance]`:
    below it, frames this host sent were not counted; above it by more than the
    segment's own traffic can account for, something was counted twice. The
    allowance comes from `ambient_allowance` and is zero on a quiet link, where
    this is the exact equality it has always been.

    What the allowance costs is worth stating rather than burying, since it is
    the reason the old `==` could not simply be kept: a drop and an ambient
    frame cancel out, so on a live segment this resolves a shortfall larger
    than `allowance` and cannot see a smaller one. Sending more frames does not
    narrow the allowance -- it is a property of the window, not of the count --
    but it does shrink it as a fraction of the run.

    The one-sidedness is deliberate too. `rx_ok` short of `expected_count` is a
    drop however busy the segment is, because ambient traffic only ever adds,
    so the low edge stays exact and the allowance is spent entirely on the
    high one.

    Every error counter must still be exactly zero. Traffic sent by `rx` is all
    well-formed, and the control run behind `allowance` shows ambient traffic
    advancing `rx_ok` alone, so one bad-classified frame is the classifier
    miscounting rather than the segment.
    """
    ok = True
    messages = []
    excess = d["rx_ok"] - expected_count
    if excess < 0:
        ok = False
        messages.append(
            f"rx_ok advanced by {d['rx_ok']}, expected {expected_count} -- at least "
            f"{-excess} frame(s) sent were not counted")
    elif excess > allowance:
        ok = False
        messages.append(
            f"rx_ok advanced by {d['rx_ok']}, expected {expected_count} plus at most "
            f"{allowance} from other traffic on the segment")
    for name in ("rx_bad", "rx_runt", "rx_over", "rx_rxer"):
        if d[name]:
            ok = False
            messages.append(f"{name} advanced by {d[name]} on traffic that was all good")
    return ok, messages


def _advance(port: StatusPort, records: int) -> gr.Record:
    """Read `records` status records and hand back the last one.

    Counting records rather than sleeping is what makes a window a known
    length: the board prints one a second, so `records` of them is `records`
    seconds of board time whatever the host's clock and the serial buffer did
    in the meantime. A `time.sleep` followed by a single read measures neither
    -- whatever is at the head of the buffer comes back, and how much board
    time separates it from the previous read is not knowable from here.
    """
    last = None
    for _ in range(records):
        last = port.read_record()
    return last


def cmd_rx(args) -> int:
    Ether, Raw, sendp, _sniff, _conf = _scapy()
    port = StatusPort(args.port)

    # The control window comes first and sends nothing. The board has no
    # address filter, so rx_ok climbs on whatever else the segment carries;
    # measuring that here is what lets this command's own frames be read back
    # out of the total afterwards. On an isolated link it measures zero and
    # costs nothing but the seconds.
    start = port.read_record()
    print(f"before: {start}")
    control_end = _advance(port, args.control)
    control = gr.deltas(start, control_end)
    print(f"control ({args.control} s, nothing sent): {gr.format_deltas(control)}")

    frames = [Ether(dst=BOARD_MAC, src=args.src, type=ETHERTYPE) / Raw(_payload(args.size, i))
              for i in range(args.count)]
    sendp(frames, iface=args.iface, verbose=False)
    print(f"sent {args.count} frames of {args.size} payload octets on {args.iface}")

    # Records, not a sleep: this window has to be a known number of board
    # seconds for the ambient rate to scale onto it, and more than one of them
    # because the first may have been printed part way through the send and
    # would undercount through no fault of the design.
    after = _advance(port, args.window)
    port.close()
    print(f"after:  {after}")

    d = gr.deltas(control_end, after)
    print(f"delta:  {gr.format_deltas(d)}")

    allowance = ambient_allowance(control["rx_ok"], args.control, args.window)
    print(f"ambient: {control['rx_ok']} frame(s) in {args.control} s with nothing sent, "
          f"so up to {allowance} of this window's {d['rx_ok']} may not be ours")

    ok, messages = evaluate_rx(d, args.count, allowance)
    for m in messages:
        print(f"FAIL {m}")

    if ok and allowance:
        print(f"note: {d['rx_ok'] - args.count} frame(s) beyond the {args.count} sent, "
              f"within the {allowance} this segment's own traffic accounts for. A "
              f"shortfall smaller than {allowance} would look the same, so this run "
              f"resolves drops of more than that many frames -- send more frames, or "
              f"isolate the segment, to sharpen it.")

    print("PASS step 4: every frame was received and classified good" if ok else "FAIL step 4")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# B.5 step 6 -- echo round trip
# --------------------------------------------------------------------------
def check_echo_frame(sent_payload: bytes, got_payload: bytes,
                      reply_dst: str, expected_src: str) -> tuple[bool, bool]:
    """(mismatched, bad_swap) for one echoed frame.

    `got_payload` is compared against the pad-extended expectation, not the
    raw sent payload, because gem_echo returns the NIC's pad along with it.
    Address comparison is case-insensitive because Scapy renders MACs
    lower-case regardless of how the caller typed them.
    """
    want = _expected_reply_payload(sent_payload)
    mismatched = got_payload[:len(want)] != want
    bad_swap = reply_dst.lower() != expected_src.lower()
    return mismatched, bad_swap


def echo_diff_octets(want: bytes, got: bytes, limit: int = 8):
    """Which octets of an echoed payload came back wrong, and what followed each.

    Returns `(index, want_octet, got_octet, next_want_octet)` per differing
    octet, capped at `limit`; `got_octet` is None where the reply ran short,
    and `next_want_octet` is None at the end of the payload.

    `next_want_octet` is in here rather than left to the reader because
    B.5-TX-1's signature is stated in terms of it: the falling-edge (high)
    nibble taking the value of the FOLLOWING rising-edge (low) nibble
    (docs/reports/stage9/known-issues.md). A differing octet on its own cannot
    show that, and the caller has the following octet right there.

    THIS REPLACED A PRINT THAT TRUNCATED BOTH PAYLOADS TO THEIR FIRST 16
    OCTETS. That was survivable while a quarter of every frame was wrong, but
    once SLEW/DRIVE cut the rate to ~2%, the surviving corruption sat past
    octet 16 and every reported line showed two identical prefixes -- the tool
    said "payload differs" and then displayed no difference. Characterising
    the residual was impossible until this was fixed, which is the kind of gap
    worth naming rather than working around.

    A reply shorter than expected counts every missing octet as differing
    instead of quietly comparing only the overlap.
    """
    out = []
    for i in range(len(want)):
        g = got[i] if i < len(got) else None
        if g == want[i]:
            continue
        out.append((i, want[i], g, want[i + 1] if i + 1 < len(want) else None))
        if len(out) == limit:
            break
    return out


def echo_diff_count(want: bytes, got: bytes) -> int:
    """How many octets differ in total, including any the reply never sent."""
    n = sum(1 for i in range(min(len(want), len(got))) if want[i] != got[i])
    return n + max(0, len(want) - len(got))


def evaluate_echo(result: EchoResult) -> bool:
    """Drops alone are expected (gem_echo buffers one frame and refuses the
    rest by design); what must be zero is corruption, and at least one frame
    must have come back or nothing was actually checked.
    """
    return result.mismatched == 0 and result.bad_swap == 0 and result.returned > 0


def cmd_echo(args) -> int:
    Ether, Raw, sendp, sniff, _conf = _scapy()
    rng = random.Random(args.seed)
    result = EchoResult()

    for i in range(args.count):
        size = rng.randint(args.min_size, args.max_size)
        payload = _payload(size, rng.randrange(256))
        frame = Ether(dst=BOARD_MAC, src=args.src, type=ETHERTYPE) / Raw(payload)

        replies = sniff(iface=args.iface, timeout=args.timeout, count=1,
                        lfilter=lambda p: (p.haslayer(Ether)
                                           and p[Ether].type == ETHERTYPE
                                           and p[Ether].src == BOARD_MAC),
                        started_callback=lambda: sendp(frame, iface=args.iface, verbose=False))
        result.sent += 1
        if not replies:
            continue
        result.returned += 1

        reply = replies[0]
        got = bytes(reply[Raw].load) if reply.haslayer(Raw) else b""
        mismatched, bad_swap = check_echo_frame(bytes(payload), got,
                                                 reply[Ether].dst, args.src)
        if mismatched:
            want = _expected_reply_payload(bytes(payload))
            result.mismatched += 1
            diffs = echo_diff_octets(want, got)
            total = echo_diff_count(want, got)
            shown = "  ".join(
                "[{}] {:02x}->{} (next {})".format(
                    idx, w,
                    "--" if g is None else "{:02x}".format(g),
                    "--" if nxt is None else "{:02x}".format(nxt))
                for idx, w, g, nxt in diffs)
            more = "" if total <= len(diffs) else "  +{} more".format(total - len(diffs))
            print(f"  frame {i}: payload differs in {total} octet(s): {shown}{more}")
        if bad_swap:
            result.bad_swap += 1
            print(f"  frame {i}: reply addressed to {reply[Ether].dst}, expected {args.src}")

    print(f"sent {result.sent}, returned {result.returned}, "
          f"payload mismatches {result.mismatched}, address swap wrong {result.bad_swap}")

    # Drops are expected and are not a failure: gem_echo buffers one frame and
    # refuses what arrives while it is busy, which is arithmetic rather than a
    # defect (see that module's header). What must be zero is corruption.
    ok = evaluate_echo(result)
    if result.returned < result.sent:
        print(f"note: {result.sent - result.returned} frame(s) did not come back. "
              f"The echo path holds one frame at a time and drops the rest by design; "
              f"only a mismatch is a failure.")
    print("PASS step 6: every returned frame was correct" if ok else "FAIL step 6")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# B.5 step 7 -- corruption, as far as a PC can produce it
# --------------------------------------------------------------------------
def evaluate_corrupt(d: dict[str, int], count: int) -> tuple[bool, list[str]]:
    """At least `count` oversize frames counted, and recovery seen (R10).

    Both are "at least" checks, not exact ones: other traffic already on the
    segment advancing rx_over or rx_ok is not a defect this command can rule
    out, and is not what it is checking for.
    """
    ok = True
    messages = []
    if d["rx_over"] < count:
        ok = False
        messages.append(f"rx_over advanced by {d['rx_over']}, expected at least {count}")
    if d["rx_ok"] < count:
        ok = False
        messages.append(f"rx_ok advanced by {d['rx_ok']} -- the receive path did not recover "
                         f"and count the good frames that followed (R10)")
    return ok, messages


def cmd_corrupt(args) -> int:
    Ether, Raw, sendp, _sniff, _conf = _scapy()
    port = StatusPort(args.port)

    before = port.read_record()
    print(f"before: {before}")

    # Oversize is the one class a NIC will actually put on the wire: it is a
    # long frame, not a malformed one, so nothing in the driver or the hardware
    # objects to it.
    oversize = Ether(dst=BOARD_MAC, src=args.src, type=ETHERTYPE) / Raw(_payload(1600, 0x40))
    sendp([oversize] * args.count, iface=args.iface, verbose=False)
    print(f"sent {args.count} oversize frames (1600 payload octets)")

    # And good traffic afterwards, because R10 is about recovery: the point is
    # not that a bad frame is counted but that the next good one still is.
    good = Ether(dst=BOARD_MAC, src=args.src, type=ETHERTYPE) / Raw(_payload(64, 0x10))
    sendp([good] * args.count, iface=args.iface, verbose=False)
    print(f"sent {args.count} good frames after them")

    time.sleep(2.5)
    after = port.read_record()
    port.close()
    print(f"after:  {after}")

    d = gr.deltas(before, after)
    print(f"delta:  {gr.format_deltas(d)}")

    ok, messages = evaluate_corrupt(d, args.count)
    for m in messages:
        print(f"FAIL {m}")

    print()
    print("NOT TESTED FROM HERE, and not because they are untested:")
    print("  bad FCS  -- the NIC computes the FCS in hardware; a corrupt one never reaches the wire")
    print("  runt     -- the NIC pads anything under 60 octets before transmitting")
    print("  RX_ER    -- asserted by the PHY, not by anything a sender can ask for")
    print("All three are covered bit-exactly in simulation against the golden model")
    print("(rx_bad_fcs, rx_runt, rx_rxer). Provoking them on hardware needs a")
    print("transmitter this host does not have -- see this file's header.")

    print("PASS step 7 (oversize + recovery)" if ok else "FAIL step 7")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# B.5 step 8 -- the soak, and the reason the readout is a UART
# --------------------------------------------------------------------------
def detect_anomalies(previous: gr.Record, current: gr.Record) -> list[str]:
    """What, if anything, is wrong between two consecutive records.

    Link-down is edge-triggered on purpose: a link that was already down and
    stays down must not report a fresh anomaly on every record for hours, and
    the link coming back up is not itself an anomaly -- only the transition
    from up to down is.
    """
    anomalies = []
    d = gr.deltas(previous, current)
    if any(d[n] for n in ("rx_bad", "rx_runt", "rx_over", "rx_rxer", "tx_urun", "tx_rej")):
        anomalies.append(gr.format_deltas(d))
    if previous.link_up and not current.link_up:
        anomalies.append("link went down")
    return anomalies


def evaluate_soak(anomaly_count: int, records: int) -> bool:
    """No anomalies, and more than one reading -- a single record proves
    nothing, which would be exactly the "watched it and it looked fine" test
    the checklist warns against.
    """
    return anomaly_count == 0 and records > 1


def cmd_soak(args) -> int:
    port = StatusPort(args.port)
    deadline = time.time() + args.hours * 3600.0
    log = open(args.log, "a", encoding="utf-8", buffering=1)

    print(f"logging to {args.log} until {time.strftime('%H:%M:%S', time.localtime(deadline))}")
    print("(traffic is not generated here -- run `echo` from another terminal, or")
    print(" point a generator at the board; this watches and records)")

    first = previous = port.read_record()
    log.write(f"# soak started {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    records = 1
    anomalies = 0

    try:
        while time.time() < deadline:
            try:
                current = port.read_record()
            except TimeoutError as exc:
                anomalies += 1
                log.write(f"# {time.strftime('%H:%M:%S')} {exc}\n")
                continue
            records += 1
            log.write(f"{time.strftime('%H:%M:%S')} {' '.join(f'{k}={v}' for k, v in current.values.items())}\n")

            for msg in detect_anomalies(previous, current):
                anomalies += 1
                print(f"{time.strftime('%H:%M:%S')} {msg}")
                log.write(f"# anomaly: {msg}\n")
            previous = current
    except KeyboardInterrupt:
        print("interrupted")
    finally:
        port.close()

    total = gr.deltas(first, previous)
    print(f"\n{records} records over {args.hours} h")
    print(f"totals: {gr.format_deltas(total)}")
    print(f"anomalies: {anomalies}")
    log.write(f"# ended {time.strftime('%Y-%m-%d %H:%M:%S')}, {records} records, {anomalies} anomalies\n")
    log.close()

    ok = evaluate_soak(anomalies, records)
    print("PASS step 8: no divergence" if ok else "FAIL step 8: see the log")
    return 0 if ok else 1


def cmd_monitor(args) -> int:
    port = StatusPort(args.port)
    previous = None
    try:
        while True:
            r = port.read_record()
            if previous is None:
                print(r)
            else:
                print(f"{r}   [{gr.format_deltas(gr.deltas(previous, r))}]")
            previous = r
    except KeyboardInterrupt:
        pass
    finally:
        port.close()
    return 0


def _records(text: str) -> int:
    """A window length in status records, which the board prints one a second."""
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("a window has to be at least one record long")
    return value


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp, needs_iface=True):
        sp.add_argument("--port", required=True, help="serial port, e.g. COM4 or /dev/ttyUSB0")
        if needs_iface:
            sp.add_argument("--iface", required=True, help="host network interface")
            sp.add_argument("--src", default="02:00:00:00:00:02", help="this host's source MAC")

    sp = sub.add_parser("monitor", help="print the status record as it arrives")
    common(sp, needs_iface=False)
    sp.set_defaults(func=cmd_monitor)

    sp = sub.add_parser("rx", help="B.5 step 4: frames in, counters advance")
    common(sp)
    sp.add_argument("--count", type=int, default=100)
    sp.add_argument("--size", type=int, default=64)
    sp.add_argument("--control", type=_records, default=4,
                    help="status records to watch before sending, measuring what the "
                         "segment's own traffic adds to rx_ok (one record a second)")
    sp.add_argument("--window", type=_records, default=3,
                    help="status records to watch after sending (one a second). More "
                         "than one, because the first may have been printed part way "
                         "through the send; shortening it narrows the ambient allowance "
                         "and lengthening it widens it, in proportion")
    sp.set_defaults(func=cmd_rx)

    sp = sub.add_parser("echo", help="B.5 step 6: round trip through the board")
    common(sp)
    sp.add_argument("--count", type=int, default=50)
    sp.add_argument("--min-size", type=int, default=46)
    sp.add_argument("--max-size", type=int, default=1500)
    sp.add_argument("--timeout", type=float, default=1.0)
    sp.add_argument("--seed", type=int, default=1)
    sp.set_defaults(func=cmd_echo)

    sp = sub.add_parser("corrupt", help="B.5 step 7: bad frames counted, good ones still received")
    common(sp)
    sp.add_argument("--count", type=int, default=20)
    sp.set_defaults(func=cmd_corrupt)

    sp = sub.add_parser("soak", help="B.5 step 8: watch and log for hours")
    common(sp, needs_iface=False)
    sp.add_argument("--hours", type=float, default=4.0)
    sp.add_argument("--log", default="soak.log")
    sp.set_defaults(func=cmd_soak)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

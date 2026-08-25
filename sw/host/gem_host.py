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
"""

from __future__ import annotations

import argparse
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
def evaluate_rx(d: dict[str, int], expected_count: int) -> tuple[bool, list[str]]:
    """Did exactly `expected_count` good frames arrive and nothing else move.

    Traffic sent by `rx` is all well-formed, so rx_ok must match the count
    exactly -- short means a drop, long means something else is on the wire --
    and every error counter must stay at zero, because one bad-classified
    frame among otherwise-correct counting is the classifier miscounting.
    """
    ok = True
    messages = []
    if d["rx_ok"] != expected_count:
        ok = False
        messages.append(f"rx_ok advanced by {d['rx_ok']}, expected {expected_count}")
    for name in ("rx_bad", "rx_runt", "rx_over", "rx_rxer"):
        if d[name]:
            ok = False
            messages.append(f"{name} advanced by {d[name]} on traffic that was all good")
    return ok, messages


def cmd_rx(args) -> int:
    Ether, Raw, sendp, _sniff, _conf = _scapy()
    port = StatusPort(args.port)

    before = port.read_record()
    print(f"before: {before}")

    frames = [Ether(dst=BOARD_MAC, src=args.src, type=ETHERTYPE) / Raw(_payload(args.size, i))
              for i in range(args.count)]
    sendp(frames, iface=args.iface, verbose=False)
    print(f"sent {args.count} frames of {args.size} payload octets on {args.iface}")

    # Two records, because one might have been mid-flight while the frames
    # arrived and would undercount through no fault of the design.
    time.sleep(2.5)
    after = port.read_record()
    port.close()
    print(f"after:  {after}")

    d = gr.deltas(before, after)
    print(f"delta:  {gr.format_deltas(d)}")

    ok, messages = evaluate_rx(d, args.count)
    for m in messages:
        print(f"FAIL {m}")

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
            print(f"  frame {i}: payload differs -- sent {want[:16].hex()}..., got {got[:16].hex()}...")
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

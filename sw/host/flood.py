#!/usr/bin/env python3
"""Offer raw Ethernet frames to the board as fast as this host manages.

The companion to `gem_host.py rate`: this supplies the load, that reads what
the board made of it. Neither knows about the other -- run this, run that, and
compare. Everything `gem_host.py` does is a Python round trip per frame, which
tops out near 440 frames/s; this exists because 0.5% of line rate is not a
measurement of a gigabit MAC.

TWO TRANSMIT PATHS, chosen with `--mode`. `--mode queue` (the default) builds
one `pcap_send_queue`, fills it with as many copies of the frame as fit, and
hands the whole queue to the kernel with one `pcap_sendqueue_transmit` call.
That removes the per-call overhead that used to cap a single sender near
18,000 frames/s, and it is the path whose numbers are quoted below. `--mode
simple` keeps the old per-call path, one kernel-mode send per frame, for hosts
without a queue-capable wpcap.dll. If the queue path cannot be set up --
wpcap.dll missing, a symbol absent, `pcap_open_live` or
`pcap_sendqueue_alloc` failing -- it prints why and falls back to `simple`
rather than refusing to run; a bench tool that refuses to run is worse than a
slow one. The output always says which path actually ran, because a
frames-per-second figure from the two paths is not comparable.

Measured 2026-08-28 against the same board and adapter:

| case | `--mode simple` | `--mode queue` |
|---|---|---|
| 1518 octets, 1 process | 18,050 fps (22.2% of line rate) | 79,257 fps (97.5%) |
| 64 octets, 1 process | 19,242 fps (1.29%) | 118,107 fps (7.9%) |
| 64 octets, 4 processes | -- | 217,893 fps (14.6%) |
| 64 octets, 8 processes | -- | 190,452 fps (12.8%), *worse than 4* |

One send-queue process beats ten per-packet processes. At 64 octets the
ceiling is the Realtek adapter and the WinPcap driver rather than this code,
which is why eight processes are slower than four; nothing here will try to
tune that.

WHY NOT iperf3. It is the obvious first idea and it is a dead end. iperf3 opens
a TCP control connection to an iperf3 *server* before it sends anything, in UDP
mode as much as TCP. `gem_top` is a MAC and an echo path: no ARP, no IP, no
TCP, nothing on the other end to connect to. The same objection retires every
generator that expects an IP peer. What the board answers to is a raw Ethertype
frame addressed to its MAC, which is all this sends.

WHY PARALLEL SENDERS HELP, AND WHEN THEY STILL DO. The old path was frame-rate
limited, not bandwidth limited: the cost is per-call overhead in the
Python/Npcap send path, it is per *process*, and it parallelises almost
linearly -- which is why ten concurrent senders were the old way to reach line
rate, and the reason `--mode simple` still has a point. With `--mode queue` a
single process is enough at maximum frame size. At minimum frame size the
adapter caps a single process at under 8% of line rate, so four concurrent
processes still help and eight hurt:

    for i in 1 2 3 4; do
      python sw/host/flood.py --iface Ethernet --seconds 50 --size 46 &
    done
    python sw/host/gem_host.py rate --port COM5 --window 30 --frame-bytes 64

WHAT THIS CANNOT DO. Minimum-size frames at *line rate*: 64 octets is
1,488,095 frames/s, which even the send queue cannot reach through this
adapter -- the Realtek and the WinPcap driver are the ceiling, measured, and
tuning against them wastes the run. That case needs Linux pktgen or DPDK. And
nothing here makes the board *transmit* at line rate -- gem_echo is the only
thing driving the transmit path and it is store-and-forward, one frame at a
time, so R7 needs RTL, not a generator.

The frame is built ONCE and the queue is filled ONCE; the transmit loop just
re-hands the same queue to the adapter, which is what the numbers above depend
on. Rebuilding a Scapy packet per send, or refilling the queue per pass, costs
more than the send does.

Everything Scapy or wpcap.dll is imported inside the functions that need it,
so importing this module is driver-free -- which is what lets test_flood.py
run on a machine with neither.
"""
from __future__ import annotations

import argparse
import ctypes
import sys
import time
from dataclasses import dataclass

# gem_host.py's, and they have to agree: gem_echo answers frames addressed to
# the board and swaps DA/SA on the way back.
BOARD_MAC = "02:00:00:00:00:01"
ETHERTYPE = 0x88B5


def mac_bytes(text: str) -> bytes:
    """'02:00:00:00:00:01' -> the six raw octets."""
    return bytes(int(b, 16) for b in text.split(":"))


def build_frame(size: int, src: str, board_mac: str = BOARD_MAC) -> bytes:
    """The raw frame this tool sends: DA, SA, Ethertype, `size` payload octets.

    The payload pattern is deterministic -- `(i * 7 + 3) & 0xFF` -- so frames
    can be told apart on the wire and matched against a capture. The NIC
    appends the FCS in hardware; add it back with `frame_on_wire` before doing
    any line-rate arithmetic.
    """
    header = mac_bytes(board_mac) + mac_bytes(src) + ETHERTYPE.to_bytes(2, "big")
    return header + bytes((i * 7 + 3) & 0xFF for i in range(size))


def frame_on_wire(frame: bytes) -> int:
    """The frame as it occupies the wire: the NIC appends a 4-octet FCS."""
    return len(frame) + 4


def line_rate_fps(on_wire: int) -> float:
    """The theoretical gigabit line rate for a frame that size on the wire.

    Matches gem_host.line_rate_fps: 20 octets of preamble, SFD and interframe
    gap per frame, so `1e9 / ((on_wire + 20) * 8)`. At 1518 octets on the wire
    that is 81274.38 frames/s; at 64 it is 1488095.24. (gem_host's version
    also refuses sizes outside 64..1518; flood.py does not, because it can be
    pointed at whatever the NIC will carry.)
    """
    return 1e9 / ((on_wire + 20) * 8)


@dataclass(frozen=True)
class Rate:
    """What `rate_arithmetic` computes -- everything a summary line needs."""
    fps: float
    mbit_per_s: float
    pct_line_rate: float


def rate_arithmetic(sent: int, elapsed: float, on_wire: int) -> Rate:
    """frames/s, Mbit/s on the wire, and percentage of the size's own line
    rate, from a frame count and an elapsed time. Zero elapsed reports zero
    rather than dividing by it."""
    fps = sent / elapsed if elapsed else 0.0
    return Rate(
        fps=fps,
        mbit_per_s=fps * on_wire * 8 / 1e6,
        pct_line_rate=100.0 * fps / line_rate_fps(on_wire),
    )


# --------------------------------------------------------------------------
# Send-queue structures. Windows keeps `long` at 32 bits in both 32- and
# 64-bit builds, so `pcap_pkthdr` is 16 bytes and `ctypes.c_long` is right;
# `c_longlong` is not. Defining these loads nothing; the wpcap.dll load is
# inside `_queue_setup` so importing this module stays driver-free.
# --------------------------------------------------------------------------
class timeval(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


class pcap_pkthdr(ctypes.Structure):
    _fields_ = [("ts", timeval), ("caplen", ctypes.c_uint), ("len", ctypes.c_uint)]


class pcap_send_queue(ctypes.Structure):
    _fields_ = [("maxlen", ctypes.c_uint), ("len", ctypes.c_uint),
                ("buffer", ctypes.POINTER(ctypes.c_char))]


class _QueueUnavailable(Exception):
    """The send-queue path cannot be set up; the caller falls back to simple."""


def _resolve_device(iface: str) -> str:
    """Friendly name or description -> the `\\Device\\NPF_{GUID}` form
    `pcap_open_live` wants. Scapy already walks the Windows registry for this;
    reimplementing pcap_findalldevs here would buy nothing."""
    from scapy.all import conf  # noqa: PLC0415  (lazy on purpose, see the header)
    try:
        from scapy.arch.windows import get_windows_if_list  # noqa: PLC0415
    except ImportError:
        get_windows_if_list = None
    if get_windows_if_list is not None:
        for device in get_windows_if_list():
            if device.get("name") == iface or device.get("description") == iface:
                return r"\Device\NPF_" + device["guid"]
    try:
        return conf.iface.network_name
    except Exception as why:
        raise _QueueUnavailable(
            f"could not resolve interface {iface!r} ({why})") from why


def _load_wpcap():
    """wpcap.dll with the send-queue symbols it must export, or a reason why
    the queue path cannot run."""
    try:
        w = ctypes.windll.LoadLibrary("wpcap.dll")
    except (OSError, AttributeError) as why:
        raise _QueueUnavailable(f"wpcap.dll could not be loaded ({why})") from why
    for name in ("pcap_open_live", "pcap_sendqueue_alloc", "pcap_sendqueue_queue",
                 "pcap_sendqueue_transmit", "pcap_sendqueue_destroy"):
        if not hasattr(w, name):
            raise _QueueUnavailable(
                f"wpcap.dll exports no {name} -- this WinPcap/Npcap build "
                "predates send queues")
    return w


def _queue_setup(args, frame: bytes):
    """Resolve the device, load wpcap.dll, and fill a send queue.

    Returns `(wpcap, handle, queue, frames_queued)`. Raises
    `_QueueUnavailable` with the reason on any failure. Every ctypes detail
    here was checked on the bench machine -- the struct layouts above, the
    restype/argtypes declarations, the device-name resolution, and the fact
    that a queue can be transmitted repeatedly without being refilled.
    """
    dev = _resolve_device(args.iface)
    print(f"device: {dev}")

    w = _load_wpcap()
    w.pcap_open_live.restype = ctypes.c_void_p
    w.pcap_open_live.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int,
                                 ctypes.c_int, ctypes.c_char_p]
    w.pcap_sendqueue_alloc.restype = ctypes.POINTER(pcap_send_queue)
    w.pcap_sendqueue_alloc.argtypes = [ctypes.c_uint]
    w.pcap_sendqueue_queue.restype = ctypes.c_int
    w.pcap_sendqueue_queue.argtypes = [ctypes.POINTER(pcap_send_queue),
                                       ctypes.POINTER(pcap_pkthdr), ctypes.c_char_p]
    w.pcap_sendqueue_transmit.restype = ctypes.c_uint
    w.pcap_sendqueue_transmit.argtypes = [ctypes.c_void_p,
                                          ctypes.POINTER(pcap_send_queue),
                                          ctypes.c_int]
    w.pcap_sendqueue_destroy.argtypes = [ctypes.POINTER(pcap_send_queue)]

    err = ctypes.create_string_buffer(512)
    handle = w.pcap_open_live(dev.encode(), 65536, 1, 100, err)
    if not handle:
        raise _QueueUnavailable("pcap_open_live failed: "
                                + err.value.decode(errors="replace"))

    q = w.pcap_sendqueue_alloc(args.queue_mb * 1024 * 1024)
    if not q:
        raise _QueueUnavailable("pcap_sendqueue_alloc failed")

    hdr = pcap_pkthdr()
    hdr.ts.tv_sec = 0
    hdr.ts.tv_usec = 0
    hdr.caplen = len(frame)
    hdr.len = len(frame)

    queued = 0
    while w.pcap_sendqueue_queue(q, ctypes.byref(hdr), frame) == 0:
        queued += 1
    if queued == 0:
        raise _QueueUnavailable("pcap_sendqueue_queue queued nothing")
    print(f"queued {queued:,} frames of {len(frame)} octets "
          f"({q.contents.len / 1024 / 1024:.1f} MB of {args.queue_mb} MB)")
    return w, handle, q, queued


def _run_queue(args, frame: bytes, on_wire: int, queue) -> int:
    w, handle, q, queued = queue
    print("mode: queue (one pcap_sendqueue_transmit per queue-full)")
    sent = 0
    passes = 0
    deadline = time.time() + args.seconds
    started = time.perf_counter()
    # sync=0: transmit as fast as the adapter accepts, ignoring the packet
    # timestamps. sync=1 would pace transmission from them, which is the
    # opposite of what a flood wants.
    while time.time() < deadline:
        n = w.pcap_sendqueue_transmit(handle, q, 0)
        passes += 1
        if n < q.contents.len:
            print(f"  short transmit: {n} of {q.contents.len} bytes")
        sent += queued
    elapsed = time.perf_counter() - started
    w.pcap_sendqueue_destroy(q)

    rate = rate_arithmetic(sent, elapsed, on_wire)
    print(f"sent {sent:,} frames in {elapsed:.2f} s over {passes} queue pass(es)")
    print(f"offered {rate.fps:,.0f} frames/s = {rate.mbit_per_s:,.1f} Mbit/s")
    print(f"that is {rate.pct_line_rate:.2f}% of the "
          f"{line_rate_fps(on_wire):,.0f} frames/s a gigabit link carries "
          f"at {on_wire} octets/frame")
    return 0


def run_simple(args, frame: bytes, on_wire: int) -> int:
    """The per-call path: one kernel-mode send per frame.

    Frame-rate limited near 18,000 frames/s whatever the frame size; kept for
    hosts without a queue-capable wpcap.dll, and for `--mode simple` given
    explicitly -- which never silently becomes something else.
    """
    print("mode: simple (one kernel-mode send per frame)")
    from scapy.all import conf  # noqa: PLC0415  (lazy on purpose, see the header)

    sock = conf.L2socket(iface=args.iface)
    # Reach past Scapy's per-packet build path to the raw handle when it is
    # exposed; fall back to the documented interface otherwise. Which one was
    # used is printed, because it is worth several thousand frames a second and
    # a rate reported without it is not comparable.
    raw_send = getattr(getattr(sock, "outs", None), "send", None)
    if raw_send is None:
        raw_send = sock.send
        print("using Scapy's socket.send (no raw pcap handle exposed)")
    else:
        print("using the raw pcap handle")

    sent = 0
    errors = 0
    deadline = time.time() + args.seconds
    started = time.perf_counter()
    try:
        while time.time() < deadline:
            for _ in range(200):        # amortise the clock read over a burst
                try:
                    raw_send(frame)
                    sent += 1
                except Exception:
                    errors += 1
                    if errors > 50:
                        raise
    except KeyboardInterrupt:
        print("interrupted")
    finally:
        elapsed = time.perf_counter() - started
        try:
            sock.close()
        except Exception:
            pass

    rate = rate_arithmetic(sent, elapsed, on_wire)
    print(f"sent {sent} frames in {elapsed:.2f} s")
    print(f"offered {rate.fps:,.0f} frames/s = {rate.mbit_per_s:,.1f} Mbit/s")
    print(f"that is {rate.pct_line_rate:.2f}% of the "
          f"{line_rate_fps(on_wire):,.0f} frames/s a gigabit link carries "
          f"at {on_wire} octets/frame")
    if errors:
        print(f"send errors: {errors}")
    return 0


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iface", required=True, help="host network interface")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--size", type=int, default=1500,
                    help="payload octets after the 14-octet header, NOT the frame size; 1500 gives a "
                         "1518-octet frame on the wire, 46 gives the 64-octet minimum")
    ap.add_argument("--src", default="02:00:00:00:00:02",
                    help="this host's source MAC")
    ap.add_argument("--mode", choices=("queue", "simple"), default="queue",
                    help="transmit path: 'queue' batches frames into one "
                         "pcap_sendqueue_transmit call (default); 'simple' is one "
                         "kernel-mode send per frame")
    ap.add_argument("--queue-mb", type=int, default=8,
                    help="send-queue buffer size in MB (mode 'queue' only)")
    return ap.parse_args(argv)


def main() -> int:
    args = parse_args()
    frame = build_frame(args.size, args.src)
    on_wire = frame_on_wire(frame)
    print(f"frame: {len(frame)} octets built, {on_wire} on the wire including FCS")
    if args.mode == "queue":
        try:
            queue = _queue_setup(args, frame)
        except _QueueUnavailable as why:
            print(f"send queue unavailable: {why}")
            print("falling back to --mode simple")
            return run_simple(args, frame, on_wire)
        return _run_queue(args, frame, on_wire, queue)
    return run_simple(args, frame, on_wire)


if __name__ == "__main__":
    sys.exit(main())

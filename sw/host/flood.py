#!/usr/bin/env python3
"""Offer raw Ethernet frames to the board as fast as this host manages.

The companion to `gem_host.py rate`: this supplies the load, that reads what
the board made of it. Neither knows about the other -- run this, run that, and
compare. Everything `gem_host.py` does is a Python round trip per frame, which
tops out near 440 frames/s; this exists because 0.5% of line rate is not a
measurement of a gigabit MAC.

WHY NOT iperf3. It is the obvious first idea and it is a dead end. iperf3 opens
a TCP control connection to an iperf3 *server* before it sends anything, in UDP
mode as much as TCP. `gem_top` is a MAC and an echo path: no ARP, no IP, no
TCP, nothing on the other end to connect to. The same objection retires every
generator that expects an IP peer. What the board answers to is a raw Ethertype
frame addressed to its MAC, which is all this sends.

RUN SEVERAL OF THESE AT ONCE. A single sender is frame-rate limited, not
bandwidth limited: measured 2026-08-28, one process managed 18,050 frames/s at
1518 octets and 19,242 frames/s at 64 -- near-identical frame rates, 219 Mbit/s
against 9.9 Mbit/s. The cost is per-call overhead in the Python/Npcap send
path, it is per *process*, and it parallelises almost linearly. Ten concurrent
senders offered 99.3% of line rate and the board received 96.05% of it with no
error counter moving. One sender reaches 21%.

    for i in 1 2 3 4 5 6 7 8 9 10; do
      python sw/host/flood.py --iface Ethernet --seconds 50 --size 1500 &
    done
    python sw/host/gem_host.py rate --port COM5 --window 30 --frame-bytes 1518

WHAT THIS CANNOT DO. Minimum-size frames at line rate: 64 octets is 1,488,095
frames/s, which at this path's per-process ceiling would need something like 77
senders. That case needs Linux pktgen or DPDK. And nothing here makes the board
*transmit* at line rate -- gem_echo is the only thing driving the transmit path
and it is store-and-forward, one frame at a time, so R7 needs RTL, not a
generator.

The frame is built ONCE and sent as raw bytes through one persistent layer-2
socket. Rebuilding a Scapy packet per send costs more than the send does.
"""
from __future__ import annotations

import argparse
import sys
import time

# gem_host.py's, and they have to agree: gem_echo answers frames addressed to
# the board and swaps DA/SA on the way back.
BOARD_MAC = "02:00:00:00:00:01"
ETHERTYPE = 0x88B5


def mac_bytes(text: str) -> bytes:
    return bytes(int(b, 16) for b in text.split(":"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iface", required=True, help="host network interface")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--size", type=int, default=1500,
                    help="payload octets after the 14-octet header; 1500 gives a "
                         "1518-octet frame on the wire, 46 gives the 64-octet minimum")
    ap.add_argument("--src", default="02:00:00:00:00:02", help="this host's source MAC")
    args = ap.parse_args()

    from scapy.all import conf  # noqa: PLC0415

    header = mac_bytes(BOARD_MAC) + mac_bytes(args.src) + ETHERTYPE.to_bytes(2, "big")
    frame = header + bytes((i * 7 + 3) & 0xFF for i in range(args.size))
    on_wire = len(frame) + 4                      # the NIC appends the FCS
    print(f"frame: {len(frame)} octets built, {on_wire} on the wire including FCS")

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

    fps = sent / elapsed if elapsed else 0.0
    # Same arithmetic as gem_host.line_rate_fps: 20 octets of preamble, SFD and
    # interframe gap per frame.
    theoretical = 1e9 / ((on_wire + 20) * 8)
    print(f"sent {sent} frames in {elapsed:.2f} s")
    print(f"offered {fps:,.0f} frames/s = {fps * on_wire * 8 / 1e6:,.1f} Mbit/s")
    print(f"that is {100.0 * fps / theoretical:.2f}% of the {theoretical:,.0f} frames/s "
          f"a gigabit link carries at {on_wire} octets/frame")
    if errors:
        print(f"send errors: {errors}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

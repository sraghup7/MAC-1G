# `sw/host` — the PC side of bring-up

Spec **B.5** lists eight steps between "the board has power" and "the MAC is
fully functional". Steps 4 to 8 need something at the other end of the cable
sending frames and reading counters. This is that something.

```bash
pip install -r requirements.txt

python gem_host.py monitor --port COM4                          # watch the counters
python gem_host.py rx      --port COM4 --iface Ethernet --count 100   # B.5 step 4
python gem_host.py echo    --port COM4 --iface Ethernet --count 100   # B.5 step 6
python gem_host.py corrupt --port COM4 --iface Ethernet               # B.5 step 7
python gem_host.py soak    --port COM4 --hours 4                      # B.5 step 8
```

`--iface` is the host's network interface (`Ethernet` on Windows, `eth0` or
similar on Linux). Raw Ethernet needs **Npcap** on Windows or **root** on Linux.
`--port` is the board's USB-UART, which enumerates as a Silicon Labs CP2102GM.

---

## What is here

| File | What it is |
|---|---|
| `gem_records.py` | Parses the status line `gem_stat_report` prints, and subtracts two of them. Pure standard library. |
| `test_gem_records.py` | Its tests, which run with no board, no serial port and nothing installed. |
| `gem_host.py` | The bring-up commands, one per B.5 step. |
| `requirements.txt` | Scapy and pyserial, both imported lazily so `monitor` works without Scapy. |

Run the tests with:

```bash
python -m unittest discover -s sw/host
```

They are part of `make check`, and they are worth having because **the record
format is a contract between two languages**. `rtl/gem_stat_report.v` prints it
and `gem_records.py` reads it, and nothing else in the build looks at both. The
two fixtures those tests parse are lines the design actually printed, copied out
of the simulation logs of `tb_gem_stat_report` and `tb_gem_top` — so if the RTL's
format changes, this fails, which is the only thing keeping the halves together.

---

## The record

```
gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000003 rx_ok=000001f4 rx_bad=00000002 rx_runt=00000000 rx_over=0000000b rx_rxer=00000000 link=00000001 speed=00000002 phyid=00221622 phyok=00000001
```

192 characters and a newline, once a second, at 115200 8N1. Every field named on
every line, every value eight hex nibbles including the one-bit ones, so a
parser has one rule rather than a width per field. Spec **B.7 item 5** has the
reasoning, including why this is a UART rather than a VIO probe: a four-hour
soak has to produce a file that can be diffed afterwards, and a JTAG probe
produces a memory of having watched some numbers.

Two properties worth knowing before reading a log:

**Every field in a line is from the same instant.** The design snapshots all
twelve when a record starts, because clocking 192 characters out takes about
17 ms and fields sampled across that window would show divergence that never
happened.

**The counters wrap, and that is expected.** They are 32 bits, which at the
worst-case frame rate wraps in about 48 minutes, against a soak of four hours or
more. `gem_records.delta()` does its arithmetic modulo 2³² for that reason;
subtracting two readings by hand will eventually report a four-billion-frame
jump backwards.

---

## What a PC cannot do, and what that means for step 7

**A commodity NIC will not transmit a bad FCS, and will not transmit a runt.**
The FCS is computed in hardware after the driver hands the frame over, and
frames under 60 octets are padded there too. This is not a Scapy limitation with
a flag to unset — the bits never reach the wire.

So of R10's four receive error classes, exactly one can be provoked from a PC:

| Class | From a PC? | Why |
|---|---|---|
| oversize | **yes** | a long frame is well-formed, just long; nothing objects |
| bad FCS | no | the NIC computes it in hardware |
| runt | no | the NIC pads to 60 octets before transmitting |
| RX_ER | no | the PHY asserts it; a sender cannot ask for it |

`corrupt` sends what it can, then good traffic behind it — because R10 is about
*recovery*, and the point is not that a bad frame is counted but that the next
good one still is. It then prints the three it could not send rather than
quietly passing.

All four classes are covered bit-exactly in simulation against the golden model
(`rx_bad_fcs`, `rx_runt`, `rx_rxer`, `rx_oversize`, and `rx_recovery_mix` for
the interleaving). What hardware adds is confidence in the PHY, the pins and the
skew — and one error class exercises those as thoroughly as four would.
Provoking the other three on a bench needs a transmitter that owns its own MAC:
a second FPGA, a traffic generator, or a NIC whose driver exposes CRC offload
controls.

---

## Echo, and why fewer frames come back than went out

The board runs `gem_echo`: a good frame is returned to its sender with the
addresses exchanged. Two consequences that look like faults and are not.

**Replies are padded.** `rx_axis_tdata` carries DA through pad (**B.4a**) — the
pad is not stripped, because with a Type-interpreted Length/Type field there is
no length in the frame to strip against. A 20-octet request comes back as a
46-octet reply. `gem_host.py` allows for this when comparing; a hand-written
comparison would report every small frame as corrupt.

**Frames are dropped under load, by design.** The echo path buffers one frame at
a time, and one arriving while another is still being transmitted is dropped
rather than queued. Echo at line rate is receive and transmit each running at
one octet per cycle, so the transmit side can never catch up once it is an
inter-frame gap behind: a host that expects every frame back at line rate is
asking for something arithmetically impossible. `echo` sends and waits, which is
why it gets everything back; a blast will not, and only a *mismatch* is a
failure.

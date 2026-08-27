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
similar on Linux). Raw Ethernet needs **root** on Linux, and on Windows a packet
driver — **Npcap**, or a legacy **WinPcap** install, which also works and is
what the bench these notes were last run from actually has (`npf` service
running, `wpcap.dll` in `System32`, no Npcap present). Worth knowing because
**Wireshark 4.6.8 refuses to run on WinPcap** and asks you to uninstall it; if
you install Wireshark to capture alongside these tools, expect to have to
choose, and expect Scapy's path to change under you.

`--port` is the board's USB-UART, which enumerates as a Silicon Labs CP210x.
**`COM4` above is an example, not a fact about your board** — it is whatever the
bridge enumerated as on your machine (COM5 on the bench these notes were last
run from). Find it with:

```powershell
Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'COM\d+' } | Select-Object Name
```

**`corrupt` (step 7) additionally needs jumbo frames enabled on the sending
NIC.** `GEM_MAX_FRAME_BYTES` is 1518 and a non-jumbo NIC caps a raw frame at
1514 + 4 octets of FCS = exactly 1518, so nothing it can send is ever oversize
and the frames never reach the wire. It fails silently — `rx_over` stays 0 and
it reads as a board defect. See `bringup_checklist.md` step 7 for the command.

---

## What is here

| File | What it is |
|---|---|
| `gem_records.py` | Parses the status line `gem_stat_report` prints, and subtracts two of them. Pure standard library. |
| `test_gem_records.py` | Its tests, which run with no board, no serial port and nothing installed. |
| `gem_host.py` | The bring-up commands, one per B.5 step. |
| `test_gem_host.py` | Tests for the pass/fail decisions inside `gem_host.py` (`evaluate_rx`, `ambient_allowance`, `check_echo_frame`, `evaluate_corrupt`, `detect_anomalies`, ...), isolated from Scapy, the serial port and each command's I/O. |
| `test_gem_host_commands.py` | Tests for the commands themselves (`cmd_rx`, `cmd_echo`, `cmd_corrupt`, `cmd_soak`) against fakes standing in for `StatusPort` and Scapy — including a fake board that misbehaves, on the same "plant the defect and watch the check catch it" principle the RTL gates in the top-level README use. |
| `requirements.txt` | Scapy and pyserial, both imported lazily so `monitor` works without Scapy. |

Run the tests with:

```bash
python -m unittest discover -s sw/host
```

They are part of `make check`, and they are worth having for two reasons.
**The record format is a contract between two languages**: `rtl/gem_stat_report.v`
prints it and `gem_records.py` reads it, and nothing else in the build looks at
both. The two fixtures `test_gem_records.py` parses are lines the design
actually printed, copied out of the simulation logs of `tb_gem_stat_report` and
`tb_gem_top` — so if the RTL's format changes, this fails, which is the only
thing keeping the halves together.

**And `gem_host.py` is what declares bring-up successful.** Every other check in
this repository is proven able to fail before it is trusted (the README's gate
table); until `test_gem_host.py` and `test_gem_host_commands.py` existed, this
was the one exception — `evaluate_rx`, `check_echo_frame`, `evaluate_corrupt`
and the commands built on them had never executed. A bug here does not cause a
build failure, a lint warning or a red simulation; it causes a `PASS` at the
bench that shouldn't be one, or a `FAIL` chasing a bug that is actually in this
file.

---

## The record

```
gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000003 rx_ok=000001f4 rx_bad=00000002 rx_runt=00000000 rx_over=0000000b rx_rxer=00000000 link=00000001 speed=00000002 phyid=00221622 phyok=00000001 rxlock=00000001
```

208 characters and a newline, once a second, at 115200 8N1. Every field named on
every line, every value eight hex nibbles including the one-bit ones, so a
parser has one rule rather than a width per field. Spec **B.7 item 5** has the
reasoning, including why this is a UART rather than a VIO probe: a four-hour
soak has to produce a file that can be diffed afterwards, and a JTAG probe
produces a memory of having watched some numbers.

Two properties worth knowing before reading a log:

**Every field in a line is from the same instant.** The design snapshots all
thirteen when a record starts, because clocking 208 characters out takes about
17 ms and fields sampled across that window would show divergence that never
happened.

**The counters wrap, and that is expected.** They are 32 bits, which at the
worst-case frame rate wraps in about 48 minutes, against a soak of four hours or
more. `gem_records.delta()` does its arithmetic modulo 2³² for that reason;
subtracting two readings by hand will eventually report a four-billion-frame
jump backwards.

---

## What the board counts, and what that means for step 4

**The board counts every frame that reaches it, whatever its destination
address.** Address filtering is **R12**, a stated non-goal, and the receive path
is promiscuous by **B.7**. So on any segment that carries other traffic — a
switch, or just a host NIC that talks mDNS and ARP to itself — `rx_ok` advances
whether or not this host is sending, and a check of the form "`rx_ok` advanced
by exactly the number sent" cannot pass. That is a property of the assertion on
a live LAN, not of the receive path; it is exactly what the first confirmed
hardware run of the fixed RX path printed (`docs/reports/stage9/known-issues.md`
§ B.5-RX-1).

`rx` handles it by measuring rather than by loosening:

1. a **control window** (`--control`, 4 status records by default) in which
   nothing is sent, giving the segment's own contribution to `rx_ok`;
2. the send;
3. a **test window** (`--window`, 3 records) in which the frames land.

Both windows are counted in *records*, not seconds slept, because the board
prints one a second — so each is a known number of board-seconds however the
host's clock and the serial buffer behaved. The control rate is scaled onto the
test window, three standard deviations of a Poisson process are added, and
`rx_ok` has to land in `[count, count + allowance]`.

Two consequences worth having in mind at the bench:

**On an isolated link nothing changes.** A control window that measures zero
produces an allowance of zero, and the check is the exact equality it always
was. The allowance is only ever as wide as the measured noise makes it.

**On a live segment the run has a resolution, and prints it.** A drop and an
ambient frame cancel, so a shortfall smaller than the allowance is invisible —
at the 1–2 frames a second this bench measured, over the default 3-second
window, that is 9 to 14 frames. The lower edge stays exact (ambient traffic
only ever *adds*, so `rx_ok` below the count sent is a drop however busy the
wire is), and the upper
edge is a bound rather than the `>=` that would let any amount of duplicate
counting through. Sending more frames does not narrow the allowance — it is a
property of the window, not the count — but it does shrink it as a fraction of
the run. Unplugging everything else shrinks it to zero.

A FAIL with a *small* excess on a run whose control window was quiet is most
likely bursty ambient traffic that missed the control window, and is worth
re-running before it is read as a defect.

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

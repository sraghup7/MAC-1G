# Flood mode (R7 / R18-min) — hardware measurement checklist

Document status: written 2026-09-01, before this has been run on hardware.
Closes the two items `docs/reports/stage9/known-issues.md` still lists as
open after the 2026-08-28 RX line-rate measurement: **R7** (the board
transmitting at line rate, in either direction) and **R18 at minimum frame
size** (the RX half was measured at 1.22% of line rate that day — host
software could not source enough parallel senders; this checklist's Part 2
is what closes it instead).

**What changed since bring-up:** `gem_traffic_gen` (RTL, task 004a) is now
wired into `gem_top` behind a new key, **KEY2** (`traffic_gen_key_n`, board
pin K14 — see `Manuals/AX7035B_pinout_notes.md` line 169), through a
frame-boundary-gated mux (task 005a) that switches the transmit port between
`gem_echo` and the generator. Both the generator's own AXI-Stream behavior
(004b-iii, 26,103 checks) and the mux itself (005b: flood frames verified
correct off simulated RGMII pins, `tx_urun=0` throughout, echo cleanly
resumes) are proven in simulation. **Nothing here has touched hardware yet
— that is the entire point of this checklist.**

**The one rule that overrides the rest**, same as `bringup_checklist.md`:
when the board and a document disagree, the board is right.

---

## Before starting

- [ ] **Commit 005a + 005b first.** `git status` currently shows
      `constrs/pins.xdc`, `rtl/gem_top.v`, `tb/tb_gem_top.sv`, and the new
      `tb/tb_gem_traffic_gen.sv` uncommitted on `charan/dev` (plus
      `scripts/run_sim.py` from 004b-ii). Build a bitstream from an
      uncommitted tree and there is no commit hash to record against it —
      every prior bring-up entry in this project's history names one
      (`build/gem_top.bit`, commit `3b8d20e`, etc.); this measurement should
      too. Commit (does not need to reach `main` yet — `CLAUDE.md`'s git
      workflow: commit freely to the working branch) before building.
- [ ] Board, JTAG cable, UART cable, Ethernet cable already connected from
      prior bring-up. Confirm the serial port — it enumerated as **COM5**
      (Silicon Labs CP210x) on this bench during Stage 5/8, but that is not
      a fact about your setup:
      ```powershell
      Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'COM\d+' } | Select-Object Name
      ```
      Substitute your own port in every command below.
- [ ] Ethernet interface name for `gem_host.py` on this PC: `Ethernet`
      (`ipconfig` / `Get-NetAdapter` if that's changed).
- [ ] `sw/host/requirements.txt` and a packet driver (Npcap/WinPcap) are
      already installed from bring-up — nothing new needed for this
      checklist, since every command below reads the board's own UART
      counters rather than sending or capturing packets.

---

## Part 1 — R7: transmit at line rate, maximum frame size (1500 payload / 1518 wire)

This is the committed default: `TRAFFIC_GEN_PAYLOAD_LEN = 1500` in
`rtl/gem_top.v` needs no edit for this part.

- [ ] Build and program:
      ```bash
      make program
      ```
      (`TOP` defaults to `gem_top`; this both builds `build/gem_top.bit` and
      programs it — `make bitstream` alone if you want to inspect the build
      before programming.)
- [ ] Confirm the board comes up the way bring-up already established: `led[0]`
      dark once both MMCMs lock, `led[2]` heartbeat blinking, `led[3]` dark
      (no sticky RX error). Nothing about this checklist should change
      normal boot.
- [ ] **Press KEY2 first, before reading any counters.** Starting the
      measurement window with flood mode already steady-state, rather than
      mid-ramp-up, is what keeps the delta below clean. (There is no LED for
      flood mode — see "What this checklist cannot tell you" — the counters
      are the only confirmation, which is what the next step is for.)
- [ ] Measure:
      ```bash
      python sw/host/gem_host.py rate --port COM5 --window 30 --frame-bytes 1518
      ```
      `--window` is in status records (one a second); 30 is a starting
      point, not a floor — see the sample-size check below before trusting
      the result.
- [ ] From the printed `delta:` line, record:
      - **`tx_urun`** — must be **0**. This is the direct hardware check of
        the property 005a's mux was specifically designed around (the
        frame-boundary-gated switch, `docs/ai_tasks/005a-wire-traffic-gen-into-top.md`'s
        Background) and 005b proved only in simulation. A nonzero count
        here means real RGMII/PHY timing broke an assumption simulation
        couldn't see — stop and treat it as a real finding, not a retry-and-
        hope.
      - **`tx_ok`** — the frame count the rate is computed from.
      - **`tx_rej`** — expected 0; `gem_traffic_gen`'s `payload_len` is
        clamped in RTL to 46..1500, so the MAC ingress should never have a
        reason to reject one of its frames. Nonzero here is also worth
        stopping on.
- [ ] **Sample-size floor (`AGENTS.md` §3): the `tx_ok` delta must be
      ≥100,000 frames before the percentage below means anything.** If it
      isn't, increase `--window` and rerun — do not report a percentage
      from a short window. State the actual `tx_ok` delta alongside the
      rate, the same way `known-issues.md`'s RX table states frame counts
      next to every percentage.
- [ ] Compute the line-rate percentage by hand: the command prints
      `tx_ok: <fps> frames/s` directly, and the theoretical ceiling for
      1518-octet frames is printed on the **`rx_ok`** line just above it
      (`... % of the <theoretical> frames/s a gigabit link can carry at
      1518 octets/frame`) — that theoretical figure is a function of frame
      size only, not direction, so it applies to `tx_ok` unchanged.
      `rate_report()` (`sw/host/gem_host.py`) only computes the percentage
      for `rx_ok` today; there was no TX-direction measurement to justify
      adding it until now. Do the division:
      `tx_ok fps / theoretical fps * 100`.
- [ ] Record the result (frames/s, % of line rate, `tx_urun`, `tx_rej`,
      sample size) — this is R7's actual hardware evidence, the entry that
      belongs in `known-issues.md` replacing "R7 remains simulation-only."
- [ ] **Press KEY2 again** to stop flood mode.
- [ ] Confirm `gem_echo` actually resumed on real hardware, not just in
      simulation — the same round trip bring-up step 6 used:
      ```bash
      python sw/host/gem_host.py echo --port COM5 --iface Ethernet
      ```
      A clean run (all frames echoed, addresses exchanged) is the hardware
      counterpart of 005b's "flood mode off, echo resumed, 1 matched".

---

## Part 2 — R18 at minimum frame size (46 payload / 64 wire), a separate session

Line rate at 64-octet frames is ~1.488M fps — the reason `known-issues.md`
records the RX half of this as still open: host software tops out at 14.6%
there (`sw/host/flood.py`'s own ceiling, the Realtek NIC/driver, not
software). `gem_traffic_gen` sources traffic from the fabric at exactly
1 octet/cycle regardless of frame size, so this is the same procedure as
Part 1 with one different constant — but there is currently no build-time
override for it (`scripts/build.tcl`/`Makefile` have no `-generic`
passthrough), so this needs a temporary source edit, not a command-line flag.

- [ ] Edit `rtl/gem_top.v`:
      ```
      parameter integer TRAFFIC_GEN_PAYLOAD_LEN = 1500
      ```
      to
      ```
      parameter integer TRAFFIC_GEN_PAYLOAD_LEN = 46
      ```
      (the module clamps to 46 as the Ethernet minimum payload regardless,
      so 46 is the smallest legal value — see `rtl/gem_traffic_gen.v`'s own
      `MIN_LEN`.)
- [ ] `make program` again.
- [ ] Same procedure as Part 1: press KEY2, then
      ```bash
      python sw/host/gem_host.py rate --port COM5 --window 30 --frame-bytes 64
      ```
      raising `--window` as needed for the same ≥100,000-frame floor —
      at minimum frame size that floor is easy to clear quickly if anywhere
      near line rate, but confirm the actual `tx_ok` delta rather than
      assuming it.
- [ ] Same `tx_urun`/`tx_rej` = 0 check, same echo-resumes check after
      pressing KEY2 again.
- [ ] Record the result the same way as Part 1 — this closes R18's
      minimum-frame-size half.
- [ ] **Revert the edit** (`TRAFFIC_GEN_PAYLOAD_LEN` back to `1500`) before
      doing anything else in this repo. `git diff rtl/gem_top.v` should show
      no change once reverted — confirm that before committing anything, so
      the committed default doesn't silently become the minimum-frame
      configuration for the next person who reads the code.

---

## What this checklist cannot tell you

- **No independent host-side capture.** Both parts measure through the
  board's own UART-reported counters (`tx_ok`, `tx_urun`, `tx_rej`) — the
  same instrument this project already used for the 2026-08-28 RX-direction
  96.05% measurement, not a second, independent one. A Wireshark capture on
  the host NIC (filtered to EtherType `0x88B5` or source MAC
  `02:00:00:00:00:01`) would corroborate that frames are actually arriving
  at the claimed rate with the right payload pattern — worth doing if the
  counters report something surprising, not required if they don't. Per
  `known-issues.md`'s still-open **V-6**, this PC's Realtek NIC/WinPcap
  cannot capture a frame's real FCS, so such a capture could confirm arrival
  and payload but not cross-check the CRC.
- **No LED for flood mode.** All four LEDs were already assigned meanings
  bring-up needed (`gem_top.v`'s own header comment); flood mode's "is it
  on" signal is entirely the UART counters. If KEY2 is pressed and `tx_ok`
  doesn't start climbing, that is the failure signal, not a dark LED.
- **This is a measurement, not a soak.** Neither part runs for hours the
  way step 8 did. If either result looks marginal (a nonzero `tx_urun`
  that's small but not zero, a percentage far below what simulation's clean
  pass would suggest), that is a reason to run longer before concluding
  anything, per the same measurement discipline `AGENTS.md` §3 states —
  three short runs of a marginal configuration have disagreed with each
  other in this project before.

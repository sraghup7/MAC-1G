# Task 4d2 report: the BUFH variant -- falsified

## Status: FALSIFIED (hypothesis dead, recorded per its own Step 5)

`Documents/RX Clock Deskew BUFH Variant.md` hypothesised that the BUFG
feedback path's ~4 ns asymmetry was a routing artifact of the global spine,
and that regional BUFH pairs in the RX clock region would shrink and symmetrise
it. Both buffers were rebuilt as BUFH (`BUFHCE_X0Y12/13`, same region as the
MMCM at MMCME2_ADV_X0Y1), the whole RX domain confined to X0Y1 by pblock, and
the design routed.

**Every RX slack came back bit-identical to the BUFG build**, to the
picosecond: setup -2.096..-2.109 / hold +1.849..+1.862 on all five ports.

Segment comparison, slow corner:

| Segment | BUFG | BUFH |
|---|---|---|
| pin to MMCM clk_in | 2.569 | 2.569 |
| MMCM internal (= minus fb) | -7.208 | -6.062 |
| forward net + cell + distribution | 3.187 | 2.041 |
| capture edge vs origin | -1.452 | **-1.452** |

Both paths shrank by exactly the same common mode (1.147 ns); their difference
-- the only thing the deskew does not cancel -- is preserved at 4.021 ns
across two radically different clock networks. A router cannot do that by
coincidence. The conclusion: **the residue is a property of the tool's model
of this deskewed-MMCM configuration, not of routing**, and no buffer topology
change can move it. Notably, 4.021 ns is close to half a unit interval; see
task-4d-report.md's "half-cycle residue" open question.

The width excess (-0.245 ns summed slack, shift-invariant) is dominated by
data-side IBUF corner spread (1.233 ns), which no clock-side change touches.

Per the BUFH variant document's own Step 5 item 2, the hypothesis is recorded
as dead rather than iterated past: no third topology gets invented inside this
task.

## What survives

* The pblock confining the RX domain to X0Y1 (`constrs/pins.xdc`) -- required
  by any BUFH-based retry and harmless otherwise.
* The `BUFH` swap itself stays in the tree with the rest of the deskew work;
  reverting it changes nothing measurable and the tree should describe the
  last thing actually built and measured.

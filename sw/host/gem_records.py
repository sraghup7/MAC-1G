#!/usr/bin/env python3
"""Parse the status records `gem_stat_report` prints, and subtract them.

THIS FILE IS ONE HALF OF A CONTRACT. The other half is `rtl/gem_stat_report.v`,
which prints one line per second like:

    gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000003 rx_ok=000001f4 \
    rx_bad=00000002 rx_runt=00000000 rx_over=0000000b rx_rxer=00000000 \
    link=00000001 speed=00000002 phyid=00221622 phyok=00000001

(one line on the wire; wrapped here to fit). Spec B.7 item 5 chose a UART over a
JTAG probe precisely so that a four-hour soak produces a file that can be
diffed, and a file nothing can parse reliably is no better than a probe.

WHY THE FIELDS ARE NAMED, AND WHY THIS PARSER IS STRICT ABOUT THEM. The format
could have been a header line and then columns, which is smaller. It is not,
because adding a counter would then silently shift every historical column and
a diff of two runs from different builds would compare tx_ok against rx_ok and
report nonsense rather than an error. Named fields make that failure loud, and
this parser keeps it loud: an unknown field name is an error rather than
something skipped, so a design that gained a counter cannot be read by a host
that does not know about it yet.

COUNTER WRAP IS EXPECTED, NOT AN ANOMALY. The counters are 32 bits, which at
B.3a's worst-case frame rate of 1.488 Mframe/s wraps in about 48 minutes -- and
B.5 step 8's acceptance test runs for at least four hours. So `delta` does its
arithmetic modulo 2**32 rather than assuming the second reading is the larger.
A host that subtracted naively would report a soak as having gone backwards by
four billion frames somewhere in its second hour.

No third-party imports here on purpose: this module is pure standard library so
its tests run anywhere, including on a machine with neither Scapy nor a serial
port nor a board.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable, Iterator

# The tag every record starts with, so a host can pick these lines out of a log
# that has boot messages or anything else in it.
TAG = "gem"

COUNTER_FIELDS = (
    "tx_ok",
    "tx_rej",
    "tx_urun",
    "rx_ok",
    "rx_bad",
    "rx_runt",
    "rx_over",
    "rx_rxer",
)

STATUS_FIELDS = (
    "link",
    "speed",
    "phyid",
    "phyok",
)

ALL_FIELDS = COUNTER_FIELDS + STATUS_FIELDS

COUNTER_MODULUS = 1 << 32

# Clause 22's speed encoding, as gem_mdio publishes it on link_speed.
SPEED_NAMES = {0: "10M", 1: "100M", 2: "1000M", 3: "reserved"}

_FIELD_RE = re.compile(r"^([a-z_]+)=([0-9a-fA-F]{1,8})$")


class RecordError(ValueError):
    """A line that claims to be a record but is not one this host understands."""


@dataclass
class Record:
    """One line of status, as a set of integers."""

    values: dict[str, int] = field(default_factory=dict)

    def __getitem__(self, name: str) -> int:
        return self.values[name]

    @property
    def link_up(self) -> bool:
        return bool(self.values["link"])

    @property
    def speed(self) -> str:
        return SPEED_NAMES.get(self.values["speed"], "?")

    @property
    def phy_id(self) -> int:
        return self.values["phyid"]

    @property
    def phy_id_valid(self) -> bool:
        return bool(self.values["phyok"])

    @property
    def errors(self) -> int:
        """Every receive-error class added together."""
        return (self.values["rx_bad"] + self.values["rx_runt"]
                + self.values["rx_over"] + self.values["rx_rxer"])

    def __str__(self) -> str:
        counters = " ".join(f"{n}={self.values[n]}" for n in COUNTER_FIELDS)
        link = "up" if self.link_up else "down"
        phy = f"{self.phy_id:08x}" if self.phy_id_valid else "invalid"
        return f"{counters} | link {link} {self.speed} phy {phy}"


def parse(line: str) -> Record:
    """Turn one record into a Record, or explain why it is not one.

    Strict on purpose. Every rejection below is a real failure mode: a truncated
    line from opening the port mid-record, a design whose field set has changed
    under a host that has not, and line noise that happens to look like text.
    """
    tokens = line.strip().split()
    if not tokens:
        raise RecordError("empty line")
    if tokens[0] != TAG:
        raise RecordError(f"line does not start with the {TAG!r} tag: {line.strip()!r}")

    values: dict[str, int] = {}
    for token in tokens[1:]:
        match = _FIELD_RE.match(token)
        if not match:
            raise RecordError(f"field {token!r} is not name=hex")
        name, text = match.group(1), match.group(2)
        if name not in ALL_FIELDS:
            raise RecordError(
                f"unknown field {name!r}. The design prints a field this host does "
                f"not know about, which means rtl/gem_stat_report.v and this file "
                f"have drifted apart -- update both rather than ignoring it")
        if name in values:
            raise RecordError(f"field {name!r} appears twice")
        values[name] = int(text, 16)

    missing = [n for n in ALL_FIELDS if n not in values]
    if missing:
        raise RecordError(
            f"record is missing {', '.join(missing)} -- most likely the line was "
            f"truncated, which happens when the port is opened part way through one")

    return Record(values)


def parse_log(lines: Iterable[str], strict: bool = False) -> Iterator[Record]:
    """Parse every record in a stream, skipping anything that is not one.

    `strict` turns a malformed record into an exception rather than a skip. The
    default is to skip, because the first line after opening a serial port is
    very often a partial one and failing on it would be theatre; a soak that
    silently skipped every line would be caught by the record count, which the
    caller has.
    """
    for line in lines:
        if not line.strip():
            continue
        try:
            yield parse(line)
        except RecordError:
            if strict:
                raise


def delta(before: Record, after: Record, name: str) -> int:
    """How much a counter advanced between two records, wrap included.

    Modulo 2**32 because the counters are that wide and a soak outruns them --
    see the note at the top of this file. This is right for any interval shorter
    than one full wrap, which at the worst-case frame rate is about 48 minutes;
    reading the counters once a second, as the design prints them, is not close
    to that.
    """
    if name not in COUNTER_FIELDS:
        raise KeyError(f"{name!r} is a status field, not a counter -- it does not accumulate")
    return (after[name] - before[name]) % COUNTER_MODULUS


def deltas(before: Record, after: Record) -> dict[str, int]:
    """Every counter's advance between two records."""
    return {name: delta(before, after, name) for name in COUNTER_FIELDS}


def format_deltas(d: dict[str, int]) -> str:
    moved = {k: v for k, v in d.items() if v}
    if not moved:
        return "no counter moved"
    return " ".join(f"{k}+{v}" for k, v in moved.items())

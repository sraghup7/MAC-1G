#!/usr/bin/env python3
"""Tests for the record parser, run with no board and no serial port.

THE TWO FIXTURES BELOW ARE NOT INVENTED. Both are lines the design actually
printed, copied out of simulation logs, and that is what makes them worth
having: a parser tested only against strings its own author made up is a parser
tested against one person's memory of a format. If `rtl/gem_stat_report.v`
changes what it prints, these stop matching and this file fails -- which is the
only mechanism keeping the two halves of the contract together, since nothing
else in the build reads both.

Run:  python -m unittest discover -s sw/host
"""

from __future__ import annotations

import unittest

import gem_records as gr


# From tb_gem_stat_report: the formatter driven with known values, everything
# populated, a plausible KSZ9031RNX PHY ID and a 1000 Mbps link.
LINE_FROM_STAT_TB = (
    "gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000003 rx_ok=000001f4 "
    "rx_bad=00000002 rx_runt=00000000 rx_over=0000000b rx_rxer=00000000 "
    "link=00000001 speed=00000002 phyid=00221622 phyok=00000001 rxlock=00000001 rx_drop=00000000"
)

# From tb_gem_top: the whole board, 12 good frames received and 6 echoed back,
# with no PHY on the MDIO bus -- so the all-ones read is reported as an invalid
# PHY ID and no link, which is the honest answer rather than a hopeful one.
# The RX deskew MMCM reports locked (the bench drives its input clock), so
# rxlock reads 1 even with no link.
LINE_FROM_TOP_TB = (
    "gem tx_ok=00000006 tx_rej=00000000 tx_urun=00000000 rx_ok=0000000c "
    "rx_bad=00000000 rx_runt=00000000 rx_over=00000000 rx_rxer=00000000 "
    "link=00000000 speed=00000002 phyid=ffffffff phyok=00000000 rxlock=00000001 rx_drop=00000000"
)


class TestParsingRealRecords(unittest.TestCase):

    def test_counters_from_the_formatter_testbench(self):
        r = gr.parse(LINE_FROM_STAT_TB)
        self.assertEqual(r["tx_ok"], 0x2A)
        self.assertEqual(r["tx_urun"], 3)
        self.assertEqual(r["rx_ok"], 500)
        self.assertEqual(r["rx_bad"], 2)
        self.assertEqual(r["rx_over"], 11)
        self.assertTrue(r.link_up)
        self.assertEqual(r.speed, "1000M")
        self.assertEqual(r.phy_id, 0x00221622)
        self.assertTrue(r.phy_id_valid)
        self.assertEqual(r.errors, 13)

    def test_board_with_no_phy_reports_no_link(self):
        r = gr.parse(LINE_FROM_TOP_TB)
        self.assertEqual(r["rx_ok"], 12)
        self.assertEqual(r["tx_ok"], 6)
        self.assertFalse(r.link_up)
        self.assertFalse(r.phy_id_valid)
        self.assertEqual(r.errors, 0)

    def test_echoed_fewer_than_received_is_not_an_error(self):
        # The echo path buffers one frame at a time and drops what arrives
        # while it is busy, so tx_ok below rx_ok is the documented behaviour
        # and a host must not treat it as loss.
        r = gr.parse(LINE_FROM_TOP_TB)
        self.assertLess(r["tx_ok"], r["rx_ok"])


class TestRejections(unittest.TestCase):
    """Every one of these is a failure that happens on a real serial port."""

    def test_line_without_the_tag(self):
        with self.assertRaises(gr.RecordError):
            gr.parse("tx_ok=00000001 rx_ok=00000001")

    def test_truncated_line(self):
        # Opening the port half way through a record produces exactly this.
        with self.assertRaises(gr.RecordError) as ctx:
            gr.parse("gem tx_ok=0000002a tx_rej=00000000")
        self.assertIn("missing", str(ctx.exception))

    def test_unknown_field_is_an_error_not_a_skip(self):
        # A design that gained a counter must not be read as though it had not.
        with self.assertRaises(gr.RecordError) as ctx:
            gr.parse(LINE_FROM_STAT_TB + " rx_pause=00000004")
        self.assertIn("drifted apart", str(ctx.exception))

    def test_duplicate_field(self):
        with self.assertRaises(gr.RecordError):
            gr.parse(LINE_FROM_STAT_TB + " rx_ok=00000001")

    def test_non_hex_value(self):
        with self.assertRaises(gr.RecordError):
            gr.parse(LINE_FROM_STAT_TB.replace("rx_ok=000001f4", "rx_ok=00000zzz"))

    def test_empty(self):
        with self.assertRaises(gr.RecordError):
            gr.parse("   ")


class TestLogStream(unittest.TestCase):

    def test_junk_between_records_is_skipped(self):
        lines = [
            "garbage from before the port settled",
            LINE_FROM_STAT_TB,
            "",
            "gem tx_ok=0000",                    # a torn line
            LINE_FROM_TOP_TB,
        ]
        records = list(gr.parse_log(lines))
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["rx_ok"], 500)
        self.assertEqual(records[1]["rx_ok"], 12)

    def test_strict_mode_refuses_a_torn_line(self):
        with self.assertRaises(gr.RecordError):
            list(gr.parse_log(["gem tx_ok=0000"], strict=True))


class TestDeltas(unittest.TestCase):

    def test_ordinary_advance(self):
        a = gr.parse(LINE_FROM_TOP_TB)
        b = gr.parse(LINE_FROM_TOP_TB.replace("rx_ok=0000000c", "rx_ok=00000064"))
        self.assertEqual(gr.delta(a, b, "rx_ok"), 88)

    def test_counters_wrap_and_the_delta_survives_it(self):
        # 32 bits at B.3a's worst-case frame rate wraps in ~48 minutes, and the
        # acceptance soak runs for four hours. A naive subtraction reports a
        # four-billion-frame jump backwards; this is the whole reason delta()
        # exists rather than callers writing b - a.
        a = gr.parse(LINE_FROM_TOP_TB.replace("rx_ok=0000000c", "rx_ok=fffffffe"))
        b = gr.parse(LINE_FROM_TOP_TB.replace("rx_ok=0000000c", "rx_ok=00000002"))
        self.assertEqual(gr.delta(a, b, "rx_ok"), 4)

    def test_status_fields_do_not_accumulate(self):
        a = b = gr.parse(LINE_FROM_TOP_TB)
        with self.assertRaises(KeyError):
            gr.delta(a, b, "link")

    def test_deltas_reports_only_what_moved(self):
        a = gr.parse(LINE_FROM_TOP_TB)
        b = gr.parse(LINE_FROM_TOP_TB.replace("rx_bad=00000000", "rx_bad=00000005"))
        self.assertEqual(gr.format_deltas(gr.deltas(a, b)), "rx_bad+5")
        self.assertEqual(gr.format_deltas(gr.deltas(a, a)), "no counter moved")


if __name__ == "__main__":
    unittest.main()

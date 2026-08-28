#!/usr/bin/env python3
"""Tests for flood.py's pure logic -- run with no adapter, no board, no serial
port, and no Scapy or wpcap.dll in play.

This file exists because the decision "is this flood fast enough to mean
anything" rests on arithmetic (frame length, line rate, the rate report) that
used to live inside a function that transmitted frames. Importing flood.py
must stay driver-free: the module loads wpcap.dll and Scapy only inside the
transmit functions, so importing it -- and with it this test suite -- works on
a machine with neither, which is the property test_gem_host.py exists to
preserve.

Run:  python -m unittest discover -s sw/host -t sw/host
"""

from __future__ import annotations

import unittest

import flood


class TestFrameBuild(unittest.TestCase):

    def test_frame_starts_with_board_mac_source_mac_then_ethertype(self):
        frame = flood.build_frame(100, "02:00:00:00:00:02")
        self.assertEqual(frame[:6], flood.mac_bytes(flood.BOARD_MAC))
        self.assertEqual(frame[6:12], flood.mac_bytes("02:00:00:00:00:02"))
        self.assertEqual(frame[12:14], flood.ETHERTYPE.to_bytes(2, "big"))

    def test_frame_length_is_the_14_octet_header_plus_the_size(self):
        self.assertEqual(len(flood.build_frame(1500, "02:00:00:00:00:02")),
                         14 + 1500)
        self.assertEqual(len(flood.build_frame(46, "02:00:00:00:00:02")),
                         14 + 46)

    def test_payload_uses_the_deterministic_pattern(self):
        frame = flood.build_frame(10, "02:00:00:00:00:02")
        self.assertEqual(frame[14:], bytes((i * 7 + 3) & 0xFF for i in range(10)))

    def test_size_1500_gives_1518_octets_on_the_wire(self):
        frame = flood.build_frame(1500, "02:00:00:00:00:02")
        self.assertEqual(flood.frame_on_wire(frame), 1518)

    def test_size_46_gives_the_64_octet_minimum_on_the_wire(self):
        frame = flood.build_frame(46, "02:00:00:00:00:02")
        self.assertEqual(len(frame), 60)
        self.assertEqual(flood.frame_on_wire(frame), 64)


class TestMacBytes(unittest.TestCase):

    def test_mac_string_becomes_six_raw_octets(self):
        self.assertEqual(flood.mac_bytes("02:00:00:00:00:01"),
                         b"\x02\x00\x00\x00\x00\x01")

    def test_mac_string_with_hex_digits(self):
        self.assertEqual(flood.mac_bytes("aa:bb:cc:dd:ee:ff"),
                         b"\xaa\xbb\xcc\xdd\xee\xff")


class TestLineRateFps(unittest.TestCase):
    # R2: the formula must match gem_host.line_rate_fps, `1e9 / ((on_wire + 20)
    # * 8)`, and both standard figures are asserted here so the values cannot
    # drift apart from that function silently.

    def test_maximum_frame_size_matches_the_standard_figure(self):
        # 1e9 / ((1518 + 20) * 8) = 1e9 / 12304 = 81274.38... frames/s.
        self.assertAlmostEqual(flood.line_rate_fps(1518), 81274.3823, delta=0.001)

    def test_minimum_frame_size_matches_the_standard_figure(self):
        # 1e9 / ((64 + 20) * 8) = 1e9 / 672 = 1488095.2381 frames/s.
        self.assertAlmostEqual(flood.line_rate_fps(64), 1488095.2381, delta=0.001)


class TestRateArithmetic(unittest.TestCase):

    def test_known_frames_and_elapsed_become_the_expected_rates(self):
        # 81274 frames in exactly 1 s at 1518 octets on the wire is 99.9995%
        # of that size's own line rate -- the sanity check the summary line
        # stands on. Mbit/s is fps * on_wire * 8 / 1e6.
        rate = flood.rate_arithmetic(81274, 1.0, 1518)
        self.assertAlmostEqual(rate.fps, 81274.0)
        self.assertAlmostEqual(rate.mbit_per_s, 81274.0 * 1518 * 8 / 1e6)
        self.assertAlmostEqual(
            rate.pct_line_rate, 100.0 * 81274.0 / flood.line_rate_fps(1518))

    def test_zero_elapsed_reports_zero_rather_than_dividing_by_zero(self):
        rate = flood.rate_arithmetic(0, 0.0, 1518)
        self.assertEqual(rate.fps, 0.0)
        self.assertEqual(rate.mbit_per_s, 0.0)
        self.assertEqual(rate.pct_line_rate, 0.0)


if __name__ == "__main__":
    unittest.main()

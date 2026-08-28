#!/usr/bin/env python3
"""Tests for gem_host's own pass/fail decisions -- run with no board, no
serial port, and no Scapy.

This file exists because the decisions in gem_host.py are the ones that
declare bring-up successful or not, and until now none of them had ever run.
Everything else in this repository is checked before it is trusted; this was
the one exception. Pure standard library, same as test_gem_records.py.

Run:  python -m unittest discover -s sw/host
"""

from __future__ import annotations

import unittest

import gem_host as gh
import gem_records as gr


def _record(**overrides) -> gr.Record:
    values = {
        "tx_ok": 0, "tx_rej": 0, "tx_urun": 0,
        "rx_ok": 0, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0,
        "rx_drop": 0,
        "link": 1, "speed": 2, "phyid": 0x00221622, "phyok": 1, "rxlock": 1,
    }
    values.update(overrides)
    return gr.Record(values)


# --------------------------------------------------------------------------
# B.5 step 4 -- evaluate_rx
# --------------------------------------------------------------------------
class TestEvaluateRx(unittest.TestCase):

    def test_exact_count_received_clean_is_ok(self):
        d = {"rx_ok": 100, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
        ok, messages = gh.evaluate_rx(d, 100)
        self.assertTrue(ok)
        self.assertEqual(messages, [])

    def test_short_count_fails(self):
        # A dropped frame must fail the step, not pass because "most" arrived.
        d = {"rx_ok": 99, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
        ok, messages = gh.evaluate_rx(d, 100)
        self.assertFalse(ok)
        self.assertTrue(any("rx_ok" in m for m in messages))

    def test_over_count_fails_when_no_ambient_traffic_was_measured(self):
        # With no allowance -- an isolated link, where the control window saw
        # nothing -- rx_ok must match exactly. More than was sent means either
        # something else is on the wire or a frame was counted twice, and this
        # is the check that used to be the only one.
        d = {"rx_ok": 101, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
        ok, _messages = gh.evaluate_rx(d, 100)
        self.assertFalse(ok)

    def test_over_count_within_the_measured_allowance_passes(self):
        # The run this whole mechanism exists for: 100 sent, 101 counted, on a
        # segment whose own traffic was measured beforehand and can account
        # for the extra one.
        d = {"rx_ok": 101, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
        ok, messages = gh.evaluate_rx(d, 100, allowance=9)
        self.assertTrue(ok)
        self.assertEqual(messages, [])

    def test_over_count_past_the_measured_allowance_still_fails(self):
        # An allowance is a bound, not a blank cheque: double counting is well
        # past what the measured ambient rate explains, and `>=` would have
        # let it through.
        d = {"rx_ok": 200, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
        ok, messages = gh.evaluate_rx(d, 100, allowance=9)
        self.assertFalse(ok)
        self.assertTrue(any("at most 9" in m for m in messages))

    def test_a_shortfall_fails_however_large_the_allowance(self):
        # The allowance is one-sided on purpose. Ambient traffic only ever
        # adds to rx_ok, so a count below what was sent is a drop no matter
        # how busy the segment is -- this is what `>=` would have given away.
        d = {"rx_ok": 99, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
        ok, messages = gh.evaluate_rx(d, 100, allowance=50)
        self.assertFalse(ok)
        self.assertTrue(any("rx_ok" in m for m in messages))

    def test_error_counters_are_not_covered_by_the_allowance(self):
        # The allowance is for rx_ok alone: the control run behind it shows
        # ambient traffic advancing rx_ok and nothing else, so a moving error
        # counter is still the classifier miscounting.
        d = {"rx_ok": 100, "rx_bad": 1, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
        ok, messages = gh.evaluate_rx(d, 100, allowance=20)
        self.assertFalse(ok)
        self.assertTrue(any("rx_bad" in m for m in messages))

    def test_any_error_counter_moving_fails_even_with_exact_rx_ok(self):
        # Traffic sent by this command is all well-formed. One bad-classified
        # frame among otherwise-correct counting means the classifier is
        # miscounting something, which is the exact defect this check exists
        # to catch.
        for name in ("rx_bad", "rx_runt", "rx_over", "rx_rxer"):
            with self.subTest(name=name):
                d = {"rx_ok": 100, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0}
                d[name] = 1
                ok, messages = gh.evaluate_rx(d, 100)
                self.assertFalse(ok)
                self.assertTrue(any(name in m for m in messages))


# --------------------------------------------------------------------------
# B.5 step 4 -- ambient_allowance
# --------------------------------------------------------------------------
class TestAmbientAllowance(unittest.TestCase):

    def test_a_quiet_control_window_allows_nothing(self):
        # The property that keeps step 4 as strict as it ever was on an
        # isolated bench: measure no ambient traffic, allow none.
        self.assertEqual(gh.ambient_allowance(0, 4, 3), 0)

    def test_measured_traffic_buys_room_in_the_test_window(self):
        # 6 frames in 4 control seconds is 1.5/s; over a 3 s window that is a
        # mean of 4.5, plus three standard deviations of 4.5 ** 0.5.
        self.assertEqual(gh.ambient_allowance(6, 4, 3), 11)

    def test_the_allowance_grows_with_the_window_it_covers(self):
        # It is a property of how long the board was watched, not of how many
        # frames were sent, which is why sending more frames sharpens the run.
        short = gh.ambient_allowance(6, 4, 2)
        long = gh.ambient_allowance(6, 4, 6)
        self.assertLess(short, long)

    def test_the_allowance_grows_with_the_measured_rate(self):
        self.assertLess(gh.ambient_allowance(2, 4, 3), gh.ambient_allowance(20, 4, 3))

    def test_a_degenerate_window_allows_nothing_rather_than_dividing_by_zero(self):
        # argparse rejects these, so this is about the function standing on
        # its own rather than about a reachable command line.
        self.assertEqual(gh.ambient_allowance(6, 0, 3), 0)
        self.assertEqual(gh.ambient_allowance(6, 4, 0), 0)


# --------------------------------------------------------------------------
# B.5 step 6 -- check_echo_frame / evaluate_echo
# --------------------------------------------------------------------------
class TestCheckEchoFrame(unittest.TestCase):

    def test_short_payload_padded_to_minimum_is_not_a_mismatch(self):
        # gem_echo returns the NIC's pad along with the payload; a host that
        # compared without allowing for it would fail every small frame.
        sent = gh._payload(20, 0x10)
        got = gh._expected_reply_payload(sent)
        mismatched, bad_swap = gh.check_echo_frame(sent, got, "02:00:00:00:00:02",
                                                     "02:00:00:00:00:02")
        self.assertFalse(mismatched)
        self.assertFalse(bad_swap)

    def test_full_size_payload_matches_exactly(self):
        sent = gh._payload(200, 0x33)
        got = sent
        mismatched, _bad_swap = gh.check_echo_frame(sent, got, "02:00:00:00:00:02",
                                                      "02:00:00:00:00:02")
        self.assertFalse(mismatched)

    def test_corrupted_payload_is_a_mismatch(self):
        sent = gh._payload(64, 0x10)
        want = gh._expected_reply_payload(sent)
        got = bytes([want[0] ^ 0xFF]) + want[1:]
        mismatched, _bad_swap = gh.check_echo_frame(sent, got, "02:00:00:00:00:02",
                                                      "02:00:00:00:00:02")
        self.assertTrue(mismatched)

    def test_reply_not_addressed_back_to_sender_is_bad_swap(self):
        sent = gh._payload(64, 0x10)
        want = gh._expected_reply_payload(sent)
        _mismatched, bad_swap = gh.check_echo_frame(
            sent, want, "02:00:00:00:00:99", "02:00:00:00:00:02")
        self.assertTrue(bad_swap)

    def test_address_comparison_is_case_insensitive(self):
        # Scapy renders MACs lower-case; a host address typed upper-case must
        # not be flagged as a swap failure over letter case alone.
        sent = gh._payload(64, 0x10)
        want = gh._expected_reply_payload(sent)
        _mismatched, bad_swap = gh.check_echo_frame(
            sent, want, "02:00:00:00:00:02", "02:00:00:00:00:02".upper())
        self.assertFalse(bad_swap)

    def test_mismatch_and_bad_swap_are_independent(self):
        sent = gh._payload(64, 0x10)
        want = gh._expected_reply_payload(sent)
        got = bytes([want[0] ^ 0xFF]) + want[1:]
        mismatched, bad_swap = gh.check_echo_frame(
            sent, got, "02:00:00:00:00:99", "02:00:00:00:00:02")
        self.assertTrue(mismatched)
        self.assertTrue(bad_swap)


class TestEchoDiffOctets(unittest.TestCase):
    """The print these back exists to characterise B.5-TX-1's residual.

    The predecessor truncated both payloads to 16 octets, so once the mismatch
    rate fell to ~2% every reported line showed two identical prefixes. These
    tests pin the properties that made it useless.
    """

    def test_identical_payloads_have_no_diffs(self):
        self.assertEqual(gh.echo_diff_octets(b"", b""), [])
        self.assertEqual(gh.echo_diff_count(b"", b""), 0)

    def test_reports_index_values_and_following_octet(self):
        want = bytes([0x79, 0x7a, 0x7b, 0x7c])
        got = bytes([0x79, 0xfa, 0x7b, 0x7c])
        self.assertEqual(gh.echo_diff_octets(want, got), [(1, 0x7a, 0xfa, 0x7b)])

    def test_finds_corruption_past_octet_16(self):
        # The exact failure that made the old print useless: identical first
        # 16 octets, damage at 42. A truncating report showed nothing at all.
        want = bytes(range(64))
        got = bytearray(want)
        got[42] ^= 0x80
        diffs = gh.echo_diff_octets(want, bytes(got))
        self.assertEqual(diffs, [(42, 42, 42 ^ 0x80, 43)])

    def test_next_octet_is_none_at_end_of_payload(self):
        want = bytes([0x10, 0x11])
        got = bytes([0x10, 0x99])
        self.assertEqual(gh.echo_diff_octets(want, got), [(1, 0x11, 0x99, None)])

    def test_short_reply_counts_missing_octets_as_differing(self):
        want = bytes([1, 2, 3, 4])
        got = bytes([1, 2])
        self.assertEqual(gh.echo_diff_count(want, got), 2)
        self.assertEqual([d[0] for d in gh.echo_diff_octets(want, got)], [2, 3])
        self.assertIsNone(gh.echo_diff_octets(want, got)[0][2])

    def test_limit_caps_the_listing_but_not_the_count(self):
        want = bytes(64)
        got = bytes([0xFF] * 64)
        self.assertEqual(len(gh.echo_diff_octets(want, got, limit=3)), 3)
        self.assertEqual(gh.echo_diff_count(want, got), 64)


class TestEvaluateEcho(unittest.TestCase):

    def test_all_returned_and_correct_is_ok(self):
        result = gh.EchoResult(sent=50, returned=50, mismatched=0, bad_swap=0)
        self.assertTrue(gh.evaluate_echo(result))

    def test_some_drops_but_no_corruption_is_still_ok(self):
        # The echo path buffers one frame and refuses the rest by design
        # (spec, gem_echo header); drops alone are not a failure.
        result = gh.EchoResult(sent=50, returned=30, mismatched=0, bad_swap=0)
        self.assertTrue(gh.evaluate_echo(result))

    def test_any_mismatch_fails(self):
        result = gh.EchoResult(sent=50, returned=50, mismatched=1, bad_swap=0)
        self.assertFalse(gh.evaluate_echo(result))

    def test_any_bad_swap_fails(self):
        result = gh.EchoResult(sent=50, returned=50, mismatched=0, bad_swap=1)
        self.assertFalse(gh.evaluate_echo(result))

    def test_nothing_returned_at_all_fails(self):
        # Zero correct is not vacuously "zero mismatches" -- it means nothing
        # was checked, which must not read as a pass.
        result = gh.EchoResult(sent=50, returned=0, mismatched=0, bad_swap=0)
        self.assertFalse(gh.evaluate_echo(result))


# --------------------------------------------------------------------------
# B.5 step 7 -- evaluate_corrupt
# --------------------------------------------------------------------------
class TestEvaluateCorrupt(unittest.TestCase):

    def test_all_oversize_counted_and_recovery_seen_is_ok(self):
        d = {"rx_over": 20, "rx_ok": 20}
        ok, messages = gh.evaluate_corrupt(d, 20)
        self.assertTrue(ok)
        self.assertEqual(messages, [])

    def test_more_than_sent_still_passes_both_thresholds(self):
        # Unlike step 4, this is an "at least" check, not an exact one: other
        # traffic on the segment advancing the same counters is not a defect.
        d = {"rx_over": 25, "rx_ok": 25}
        ok, _messages = gh.evaluate_corrupt(d, 20)
        self.assertTrue(ok)

    def test_oversize_undercounted_fails(self):
        d = {"rx_over": 19, "rx_ok": 20}
        ok, messages = gh.evaluate_corrupt(d, 20)
        self.assertFalse(ok)
        self.assertTrue(any("rx_over" in m for m in messages))

    def test_no_recovery_after_bad_traffic_fails(self):
        # This is R10: the point is not that the bad frame was counted, but
        # that the receive path kept working afterwards.
        d = {"rx_over": 20, "rx_ok": 5}
        ok, messages = gh.evaluate_corrupt(d, 20)
        self.assertFalse(ok)
        self.assertTrue(any("recover" in m for m in messages))


# --------------------------------------------------------------------------
# B.5 step 8 -- detect_anomalies / evaluate_soak
# --------------------------------------------------------------------------
class TestDetectAnomalies(unittest.TestCase):

    def test_quiet_interval_has_no_anomalies(self):
        a = _record(rx_ok=10)
        b = _record(rx_ok=20)
        self.assertEqual(gh.detect_anomalies(a, b), [])

    def test_any_error_counter_advancing_is_an_anomaly(self):
        for name in ("rx_bad", "rx_runt", "rx_over", "rx_rxer", "tx_urun", "tx_rej"):
            with self.subTest(name=name):
                a = _record()
                b = _record(**{name: 1})
                anomalies = gh.detect_anomalies(a, b)
                self.assertEqual(len(anomalies), 1)

    def test_link_dropping_is_an_anomaly(self):
        a = _record(link=1)
        b = _record(link=0)
        anomalies = gh.detect_anomalies(a, b)
        self.assertTrue(any("link" in m for m in anomalies))

    def test_link_staying_down_is_not_a_repeated_anomaly(self):
        # Edge-triggered: a link that was already down and stays down must
        # not report a fresh anomaly on every record for hours.
        a = _record(link=0)
        b = _record(link=0)
        self.assertEqual(gh.detect_anomalies(a, b), [])

    def test_link_coming_back_up_is_not_itself_an_anomaly(self):
        a = _record(link=0)
        b = _record(link=1)
        self.assertEqual(gh.detect_anomalies(a, b), [])

    def test_counter_and_link_anomaly_together_are_both_reported(self):
        a = _record(link=1, rx_bad=0)
        b = _record(link=0, rx_bad=1)
        anomalies = gh.detect_anomalies(a, b)
        self.assertEqual(len(anomalies), 2)


class TestEvaluateSoak(unittest.TestCase):

    def test_no_anomalies_and_more_than_one_record_is_ok(self):
        self.assertTrue(gh.evaluate_soak(anomaly_count=0, records=100))

    def test_any_anomaly_fails(self):
        self.assertFalse(gh.evaluate_soak(anomaly_count=1, records=100))

    def test_only_one_record_ever_read_fails_even_with_no_anomalies(self):
        # A soak that never got a second reading proves nothing; passing it
        # would be exactly the "watched it and it looked fine" test the
        # checklist warns against.
        self.assertFalse(gh.evaluate_soak(anomaly_count=0, records=1))


# --------------------------------------------------------------------------
# StatusPort's retry/skip logic, isolated from the serial port itself
# --------------------------------------------------------------------------
class TestReadRecordFromLines(unittest.TestCase):

    LINE = ("gem tx_ok=0000002a tx_rej=00000000 tx_urun=00000003 rx_ok=000001f4 "
            "rx_bad=00000002 rx_runt=00000000 rx_over=0000000b rx_rxer=00000000 "
            "link=00000001 speed=00000002 phyid=00221622 phyok=00000001 rxlock=00000001 rx_drop=00000000")

    def test_first_line_valid_is_returned(self):
        record = gh._read_record_from_lines(iter([self.LINE]), tries=4)
        self.assertEqual(record["rx_ok"], 500)

    def test_blank_lines_are_skipped_within_the_retry_budget(self):
        lines = iter(["", "   ", self.LINE])
        record = gh._read_record_from_lines(lines, tries=4)
        self.assertEqual(record["rx_ok"], 500)

    def test_a_torn_line_from_opening_mid_record_is_skipped(self):
        lines = iter(["gem tx_ok=0000", self.LINE])
        record = gh._read_record_from_lines(lines, tries=4)
        self.assertEqual(record["rx_ok"], 500)

    def test_exhausting_tries_on_garbage_raises_timeout(self):
        lines = iter(["", "garbage", "gem tx_ok=0000"])
        with self.assertRaises(TimeoutError) as ctx:
            gh._read_record_from_lines(lines, tries=3)
        self.assertIn("no complete status record", str(ctx.exception))

    def test_tries_is_a_hard_budget_not_a_minimum(self):
        # A valid record arriving on try 4 must not be read if tries=3 -- the
        # caller chose that budget deliberately (StatusPort docs it as the
        # number of one-second lines it is willing to wait through).
        lines = iter(["", "", "", self.LINE])
        with self.assertRaises(TimeoutError):
            gh._read_record_from_lines(lines, tries=3)


# --------------------------------------------------------------------------
# line rate -- the pure arithmetic behind `rate`
# --------------------------------------------------------------------------
class TestLineRateFps(unittest.TestCase):

    def test_maximum_frame_size_matches_the_standard_figure(self):
        # 1e9 / ((1518 + 20) * 8) = 1e9 / 12304. The commonly published gigabit
        # figure is 81,274 frames/s, and this agrees with it.
        #
        # The task contract that asked for this function stated 81275.2, which
        # is simply wrong; it went unnoticed only because that contract also
        # allowed a one-frame tolerance. Asserted tightly here so the error
        # cannot be inherited by whatever reads this next.
        self.assertAlmostEqual(gh.line_rate_fps(1518), 81274.3823, delta=0.001)

    def test_minimum_frame_size_matches_the_standard_figure(self):
        # 1e9 / ((64 + 20) * 8) = 1e9 / 672.
        self.assertAlmostEqual(gh.line_rate_fps(64), 1488095.2381, delta=0.001)

    def test_below_the_minimum_is_rejected(self):
        with self.assertRaises(ValueError):
            gh.line_rate_fps(63)

    def test_above_the_maximum_is_rejected(self):
        # A 9000-octet jumbo frame is a question the gigabit formula does not
        # answer; refusing beats returning a number that has no meaning.
        with self.assertRaises(ValueError):
            gh.line_rate_fps(9000)


class TestRateReport(unittest.TestCase):
    """The R2 pure function: deltas over a timed window become rates, and the
    percentage is against the frame size's own line rate. No I/O here -- the
    printing is cmd_rate's job.
    """

    def _rates(self, after, seconds=2.0, frame_bytes=1518):
        before = _record()
        return gh.rate_report(gr.deltas(before, after), seconds, frame_bytes)

    def test_deltas_over_a_window_become_rates(self):
        r = self._rates(_record(rx_ok=50, rx_drop=5, tx_ok=10))
        self.assertEqual(r["rx_ok_per_s"], 25.0)
        self.assertEqual(r["rx_bad_per_s"], 0.0)
        self.assertEqual(r["rx_drop_per_s"], 2.5)
        self.assertEqual(r["tx_ok_per_s"], 5.0)

    def test_a_one_second_window_makes_each_delta_its_own_rate(self):
        # The sanity check the arithmetic stands on: 100 frames in 1 s is 100/s.
        r = self._rates(_record(rx_ok=100), seconds=1.0)
        self.assertEqual(r["rx_ok_per_s"], 100.0)

    def test_the_percentage_is_of_the_frame_sizes_own_line_rate(self):
        # Same count, twice the window: half the rate, half the percentage.
        r = self._rates(_record(rx_ok=50), seconds=2.0)
        self.assertAlmostEqual(
            r["rx_ok_pct_line_rate"],
            100.0 * 25.0 / gh.line_rate_fps(1518))
        r2 = self._rates(_record(rx_ok=50), seconds=4.0)
        self.assertAlmostEqual(r2["rx_ok_pct_line_rate"], r["rx_ok_pct_line_rate"] / 2)

    def test_a_non_positive_window_is_rejected(self):
        # A zero or negative window cannot produce a rate; refusing beats
        # dividing by it.
        with self.assertRaises(ValueError):
            gh.rate_report(gr.deltas(_record(), _record(rx_ok=5)), 0.0, 1518)
        with self.assertRaises(ValueError):
            gh.rate_report(gr.deltas(_record(), _record(rx_ok=5)), -1.0, 1518)


if __name__ == "__main__":
    unittest.main()

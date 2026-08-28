#!/usr/bin/env python3
"""Orchestration tests for gem_host's B.5 subcommands themselves.

test_gem_host.py checks the extracted decision functions (evaluate_rx,
check_echo_frame, ...) in isolation. This file checks the commands that call
them -- cmd_rx, cmd_echo, cmd_corrupt -- end to end: argument parsing into a
verdict and an exit code, with StatusPort and Scapy replaced by fakes so
nothing here needs a board, a serial port, Npcap or root.

Until this file existed, cmd_rx/cmd_echo/cmd_corrupt had never executed even
once. Following this repo's own rule that a check that cannot fail is not a
check (see README's gate table), each class below plants one defect in the
fake board's behaviour and confirms the affected test turns red before
confirming the well-behaved board turns it green -- the same proof style
`tb_gem_top` uses for D6/D7/D8, applied here to host-side logic instead of
RTL.

Run:  python -m unittest discover -s sw/host
"""

from __future__ import annotations

import contextlib
import io
import types
import unittest
from unittest import mock

import gem_host as gh
import gem_records as gr


def _args(**kwargs) -> types.SimpleNamespace:
    # control/window are cmd_rx's two window lengths, in status records. One
    # each here keeps the scripted record sequences below short; the real
    # defaults are 4 and 3, and nothing in cmd_rx cares which.
    defaults = dict(port="COM_FAKE", iface="fake0", src="02:00:00:00:00:02",
                    control=1, window=1)
    defaults.update(kwargs)
    return types.SimpleNamespace(**defaults)


def _record(**overrides) -> gr.Record:
    values = {
        "tx_ok": 0, "tx_rej": 0, "tx_urun": 0,
        "rx_ok": 0, "rx_bad": 0, "rx_runt": 0, "rx_over": 0, "rx_rxer": 0,
        "rx_drop": 0,
        "link": 1, "speed": 2, "phyid": 0x00221622, "phyok": 1, "rxlock": 1,
    }
    values.update(overrides)
    return gr.Record(values)


class FakeStatusPort:
    """Hands back a scripted sequence of records instead of opening a port."""

    def __init__(self, records):
        self._records = list(records)
        self._i = 0
        self.closed = False

    @property
    def consumed(self) -> int:
        """How many records the caller actually read -- which is how long its
        window was, since the board prints one a second."""
        return self._i

    def read_record(self, tries: int = 4) -> gr.Record:
        if self._i >= len(self._records):
            raise TimeoutError("FakeStatusPort exhausted its scripted records")
        r = self._records[self._i]
        self._i += 1
        return r

    def close(self) -> None:
        self.closed = True


class FakeRaw:
    def __init__(self, load: bytes = b""):
        self.load = bytes(load)


class FakeEther:
    def __init__(self, dst=None, src=None, type=None):
        self.dst = dst
        self.src = src
        self.type = type
        self.payload = None

    def __truediv__(self, other):
        pkt = FakeEther(dst=self.dst, src=self.src, type=self.type)
        pkt.payload = other
        return pkt

    def haslayer(self, cls):
        if cls is FakeEther:
            return True
        if cls is FakeRaw:
            return isinstance(self.payload, FakeRaw)
        return False

    def __getitem__(self, cls):
        if cls is FakeEther:
            return self
        if cls is FakeRaw and isinstance(self.payload, FakeRaw):
            return self.payload
        raise KeyError(cls)


class FakeScapy:
    """Stands in for scapy.all: records what was sent, and lets a test-supplied
    `board` callable decide what (if anything) answers it -- the fake plays
    the part real hardware plays in `echo`'s sniff/sendp round trip.
    """

    def __init__(self, board=None):
        self.board = board
        self.sent: list = []

    def sendp(self, pkts, iface=None, verbose=None):
        self.sent.extend(pkts if isinstance(pkts, list) else [pkts])

    def sniff(self, iface, timeout, count, lfilter=None, started_callback=None):
        if started_callback:
            started_callback()
        if self.board is None:
            return []
        reply = self.board(self.sent[-1])
        if reply is None:
            return []
        if lfilter and not lfilter(reply):
            return []
        return [reply]

    def bundle(self):
        return FakeEther, FakeRaw, self.sendp, self.sniff, None


def _patch_scapy(scapy: FakeScapy):
    return mock.patch.object(gh, "_scapy", lambda: scapy.bundle())


def _patch_port(port: FakeStatusPort):
    return mock.patch.object(gh, "StatusPort", lambda *a, **kw: port)


def _patch_sleep():
    # cmd_corrupt sleeps 2.5s for the second status record to arrive. Real
    # hardware needs that; a fake board answers instantly. cmd_rx counts
    # records instead of sleeping, so it does not need this.
    return mock.patch.object(gh.time, "sleep", lambda *_a: None)


# --------------------------------------------------------------------------
# cmd_rx
# --------------------------------------------------------------------------
class TestCmdRx(unittest.TestCase):
    """cmd_rx reads three records at --control 1 --window 1: the start of the
    control window, its end (nothing has been sent yet, so the advance between
    those two is the segment's own traffic), and the end of the test window.
    """

    def _run(self, records, **kwargs):
        port = FakeStatusPort(records)
        out = io.StringIO()
        with _patch_port(port), _patch_scapy(FakeScapy()):
            with contextlib.redirect_stdout(out):
                rc = gh.cmd_rx(_args(count=10, size=64, **kwargs))
        return rc, out.getvalue(), port

    def test_clean_run_on_a_quiet_link_passes(self):
        rc, _out, port = self._run(
            [_record(rx_ok=0), _record(rx_ok=0), _record(rx_ok=10)])
        self.assertEqual(rc, 0)
        self.assertTrue(port.closed)

    def test_dropped_frame_fails(self):
        # The board only counted 9 of the 10 frames sent.
        rc, out, _port = self._run(
            [_record(rx_ok=0), _record(rx_ok=0), _record(rx_ok=9)])
        self.assertEqual(rc, 1)
        self.assertIn("rx_ok advanced by 9", out)

    def test_a_misclassified_frame_fails_even_with_the_right_count(self):
        rc, _out, _port = self._run([_record(rx_ok=0, rx_bad=0),
                                     _record(rx_ok=0, rx_bad=0),
                                     _record(rx_ok=10, rx_bad=1)])
        self.assertEqual(rc, 1)

    def test_a_quiet_control_window_keeps_the_check_exact(self):
        # Nothing moved with nothing sent, so one extra frame is still a FAIL:
        # the allowance is measured, and on this link it measures zero.
        rc, out, _port = self._run(
            [_record(rx_ok=0), _record(rx_ok=0), _record(rx_ok=11)])
        self.assertEqual(rc, 1)
        self.assertIn("plus at most 0", out)

    def test_ambient_traffic_measured_in_the_control_window_is_allowed_for(self):
        # Four frames arrived in the control second with nothing sent, so a
        # window carrying the 10 sent plus three more is the same segment
        # behaving the same way -- this is the run that used to FAIL.
        rc, out, _port = self._run(
            [_record(rx_ok=0), _record(rx_ok=4), _record(rx_ok=17)])
        self.assertEqual(rc, 0)
        self.assertIn("3 frame(s) beyond the 10 sent", out)

    def test_more_than_the_measured_ambient_rate_explains_still_fails(self):
        # Same 4-per-second control window, but 40 frames beyond the 10 sent.
        # An allowance derived from the measured rate does not cover that, so
        # duplicate counting is still caught.
        rc, out, _port = self._run(
            [_record(rx_ok=0), _record(rx_ok=4), _record(rx_ok=54)])
        self.assertEqual(rc, 1)
        self.assertIn("rx_ok advanced by 50", out)

    def test_a_drop_fails_even_on_a_busy_segment(self):
        # The allowance is one-sided: ambient traffic only ever adds, so rx_ok
        # short of the count sent is a drop no matter how loud the segment is.
        rc, out, _port = self._run(
            [_record(rx_ok=0), _record(rx_ok=4), _record(rx_ok=13)])
        self.assertEqual(rc, 1)
        self.assertIn("were not counted", out)

    def test_the_window_is_counted_in_records_not_seconds_slept(self):
        # --window 3 must consume three records after the control window, so
        # the delta spans a known three board-seconds. A cmd_rx that slept and
        # read one record would leave two unread and pass this by accident, so
        # the assertion is on the records consumed, not only the verdict.
        records = [_record(rx_ok=0), _record(rx_ok=0),
                   _record(rx_ok=4), _record(rx_ok=7), _record(rx_ok=10)]
        rc, _out, port = self._run(records, window=3)
        self.assertEqual(rc, 0)
        self.assertEqual(port.consumed, 5)

    def test_the_wiring_itself_can_fail(self):
        # Proof this test can catch a real regression: plant a defect in the
        # wiring (compare against the wrong field) and confirm the clean-run
        # test above would have gone red, not green regardless of the board.
        port = FakeStatusPort([_record(rx_ok=0), _record(rx_ok=0), _record(rx_ok=10)])
        broken_evaluate_rx = lambda d, count, allowance=0: (False, ["planted defect"])
        with _patch_port(port), _patch_scapy(FakeScapy()), \
             mock.patch.object(gh, "evaluate_rx", broken_evaluate_rx):
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_rx(_args(count=10, size=64))
        self.assertEqual(rc, 1)


# --------------------------------------------------------------------------
# cmd_echo
# --------------------------------------------------------------------------
def _well_behaved_board(request: FakeEther) -> FakeEther:
    sent_payload = bytes(request.payload.load)
    reply_payload = gh._expected_reply_payload(sent_payload)
    return FakeEther(dst=request.src, src=gh.BOARD_MAC, type=gh.ETHERTYPE) / FakeRaw(reply_payload)


def _board_that_forgets_to_swap_addresses(request: FakeEther) -> FakeEther:
    sent_payload = bytes(request.payload.load)
    reply_payload = gh._expected_reply_payload(sent_payload)
    # Replies to itself instead of back to the sender.
    return FakeEther(dst=gh.BOARD_MAC, src=gh.BOARD_MAC, type=gh.ETHERTYPE) / FakeRaw(reply_payload)


def _board_that_corrupts_one_octet(request: FakeEther) -> FakeEther:
    sent_payload = bytes(request.payload.load)
    reply_payload = bytearray(gh._expected_reply_payload(sent_payload))
    reply_payload[0] ^= 0xFF
    return FakeEther(dst=request.src, src=gh.BOARD_MAC, type=gh.ETHERTYPE) / FakeRaw(bytes(reply_payload))


class TestCmdEcho(unittest.TestCase):

    def test_well_behaved_board_passes(self):
        scapy = FakeScapy(board=_well_behaved_board)
        with _patch_scapy(scapy):
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_echo(_args(count=5, min_size=46, max_size=200,
                                        timeout=1.0, seed=1))
        self.assertEqual(rc, 0)

    def test_board_that_does_not_swap_addresses_fails(self):
        scapy = FakeScapy(board=_board_that_forgets_to_swap_addresses)
        with _patch_scapy(scapy):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = gh.cmd_echo(_args(count=5, min_size=46, max_size=200,
                                        timeout=1.0, seed=1))
        self.assertEqual(rc, 1)
        self.assertIn("expected 02:00:00:00:00:02", out.getvalue())

    def test_board_that_corrupts_payload_fails(self):
        scapy = FakeScapy(board=_board_that_corrupts_one_octet)
        with _patch_scapy(scapy):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = gh.cmd_echo(_args(count=5, min_size=46, max_size=200,
                                        timeout=1.0, seed=1))
        self.assertEqual(rc, 1)
        self.assertIn("payload differs", out.getvalue())

    def test_a_silent_board_that_drops_everything_fails(self):
        # Not the same as "some drops are fine" -- nothing came back at all.
        scapy = FakeScapy(board=lambda request: None)
        with _patch_scapy(scapy):
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_echo(_args(count=5, min_size=46, max_size=200,
                                        timeout=1.0, seed=1))
        self.assertEqual(rc, 1)

    def test_some_drops_among_correct_replies_still_passes(self):
        calls = {"n": 0}

        def flaky_board(request):
            calls["n"] += 1
            if calls["n"] % 2 == 0:
                return None
            return _well_behaved_board(request)

        scapy = FakeScapy(board=flaky_board)
        with _patch_scapy(scapy):
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_echo(_args(count=6, min_size=46, max_size=200,
                                        timeout=1.0, seed=1))
        self.assertEqual(rc, 0)


# --------------------------------------------------------------------------
# cmd_corrupt
# --------------------------------------------------------------------------
class TestCmdCorrupt(unittest.TestCase):

    def test_oversize_counted_and_recovery_seen_passes(self):
        port = FakeStatusPort([_record(rx_over=0, rx_ok=0),
                                _record(rx_over=20, rx_ok=20)])
        with _patch_port(port), _patch_scapy(FakeScapy()), _patch_sleep():
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_corrupt(_args(count=20))
        self.assertEqual(rc, 0)

    def test_receive_path_that_does_not_recover_fails(self):
        # All the oversize frames were counted, but the good frames sent
        # afterwards were not -- R10's recovery half did not happen.
        port = FakeStatusPort([_record(rx_over=0, rx_ok=0),
                                _record(rx_over=20, rx_ok=0)])
        with _patch_port(port), _patch_scapy(FakeScapy()), _patch_sleep():
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = gh.cmd_corrupt(_args(count=20))
        self.assertEqual(rc, 1)
        self.assertIn("did not recover", out.getvalue())

    def test_undercounted_oversize_fails(self):
        port = FakeStatusPort([_record(rx_over=0, rx_ok=0),
                                _record(rx_over=15, rx_ok=20)])
        with _patch_port(port), _patch_scapy(FakeScapy()), _patch_sleep():
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_corrupt(_args(count=20))
        self.assertEqual(rc, 1)


# --------------------------------------------------------------------------
# cmd_soak
# --------------------------------------------------------------------------
_BASE = 1_700_000_000.0  # a real-looking epoch, so time.localtime() never sees a negative argument


class TestCmdSoak(unittest.TestCase):
    """cmd_soak's own loop runs on wall-clock time, which a test cannot wait
    out for real. `gh.time.time` is patched with a scripted sequence instead
    -- the deadline calculation, then one `time.time() < deadline` check per
    prospective iteration -- so the number of records read is exact and the
    test runs in milliseconds rather than hours.
    """

    def test_quiet_soak_over_two_intervals_passes(self):
        # deadline = 0 + 1h*3600 = 3600. Two loop checks land inside it (10,
        # 20), the third (4000) is past it and ends the loop: two iterations,
        # three records read in total (the initial one plus two in-loop).
        port = FakeStatusPort([_record(rx_ok=0), _record(rx_ok=1), _record(rx_ok=2)])
        with _patch_port(port), \
             mock.patch.object(gh.time, "time", side_effect=[_BASE, _BASE + 10, _BASE + 20, _BASE + 4000]), \
             tempfile_path() as log_path:
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_soak(_args(hours=1.0, log=log_path))
        self.assertEqual(rc, 0)
        self.assertTrue(port.closed)

    def test_an_error_counter_advancing_mid_soak_fails(self):
        port = FakeStatusPort([_record(rx_bad=0), _record(rx_bad=0), _record(rx_bad=1)])
        with _patch_port(port), \
             mock.patch.object(gh.time, "time", side_effect=[_BASE, _BASE + 10, _BASE + 20, _BASE + 4000]), \
             tempfile_path() as log_path:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = gh.cmd_soak(_args(hours=1.0, log=log_path))
        self.assertEqual(rc, 1)
        self.assertIn("rx_bad", out.getvalue())

    def test_a_link_drop_mid_soak_fails(self):
        port = FakeStatusPort([_record(link=1), _record(link=1), _record(link=0)])
        with _patch_port(port), \
             mock.patch.object(gh.time, "time", side_effect=[_BASE, _BASE + 10, _BASE + 20, _BASE + 4000]), \
             tempfile_path() as log_path:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = gh.cmd_soak(_args(hours=1.0, log=log_path))
        self.assertEqual(rc, 1)
        self.assertIn("link went down", out.getvalue())

    def test_deadline_already_past_reads_only_the_first_record_and_fails(self):
        # A single record proves nothing -- the exact "watched it and it
        # looked fine" case the checklist warns against -- so a non-positive
        # --hours must not read as a vacuous pass.
        port = FakeStatusPort([_record(rx_ok=0)])
        with _patch_port(port), \
             mock.patch.object(gh.time, "time", side_effect=[_BASE, _BASE - 1]), \
             tempfile_path() as log_path:
            with contextlib.redirect_stdout(io.StringIO()):
                rc = gh.cmd_soak(_args(hours=-1.0, log=log_path))
        self.assertEqual(rc, 1)


@contextlib.contextmanager
def tempfile_path():
    import os as _os
    import tempfile as _tempfile
    fd, path = _tempfile.mkstemp(prefix="gem_soak_test_")
    _os.close(fd)
    try:
        yield path
    finally:
        _os.remove(path)


if __name__ == "__main__":
    unittest.main()

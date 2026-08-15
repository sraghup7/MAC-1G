classdef tAbort < matlab.unittest.TestCase
    %TABORT Spec B.4b: what the TX path emits when user logic starves it.
    %
    %   B.4b makes three choices that are decisions rather than arithmetic, and
    %   each one would look entirely plausible if it were made the other way.
    %   These tests exist to pin them down, because a golden model that quietly
    %   drifted on any of them would demand the wrong thing of the RTL and be
    %   believed:
    %
    %     1. no padding on an aborted frame
    %     2. the FCS is inverted, so the frame is guaranteed to fail a check
    %     3. TX_ER rides the FCS octets only, not the whole frame
    %
    %   The last group checks the property that makes any of this testable: an
    %   aborted frame's content does not depend on the MAC's pipeline depth.

    properties (Constant)
        DA = uint8([0 10 53 1 2 3])
        SA = uint8([222 173 190 239 0 1])
        ET = 2048
    end

    methods (Test)

        function abortedFrameCarriesOnlyWhatWasSent(tc)
            % The MAC cannot transmit octets the user never handed it. An abort
            % after 60 payload octets puts preamble + SFD + header + those 60 +
            % FCS on the wire, and nothing else.
            p = gem.params();
            payload = uint8(mod(0:199, 251));
            f = gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, 60);

            expected = p.PREAMBLE_BYTES + 1 + p.HEADER_BYTES + 60 + p.FCS_BYTES;
            tc.verifyEqual(numel(f.packetBytes), expected);
            tc.verifyEqual(f.sentPayload, payload(1:60));
        end

        function abortedFrameIsNotPadded(tc)
            % Decision 1. Padding completes a frame (R3); an abort does not
            % complete anything. A model that padded to the 46-octet minimum
            % here would make the RTL emit pad octets it has no reason to
            % generate, and the mismatch would be blamed on the design.
            p = gem.params();
            payload = uint8(mod(0:99, 251));
            f = gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, 10);

            expected = p.PREAMBLE_BYTES + 1 + p.HEADER_BYTES + 10 + p.FCS_BYTES;
            tc.verifyEqual(numel(f.packetBytes), expected, ...
                'an aborted frame was padded; B.4b says it must not be');
        end

        function fcsIsInvertedNotMerelyDifferent(tc)
            % Decision 2, first half: every bit flipped, exactly.
            payload = uint8(mod(0:99, 251));
            f = gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, 60);

            tc.verifyEqual(f.fcs, bitcmp(f.goodFcs));
            tc.verifyNotEqual(f.fcs, f.goodFcs);
        end

        function abortedFrameFailsTheReceiverCheck(tc)
            % Decision 2, second half, and the one that actually matters: the
            % point of inverting is that the frame is guaranteed to be rejected.
            % Verifying the inversion arithmetic alone would not prove that --
            % this runs the frame through the real RX path and requires a
            % verdict of bad.
            for stallAt = [1 10 46 60 200]
                payload = uint8(mod(0:299, 251));
                f = gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, stallAt);
                r = gem.parseFrame(f.frameBytes);

                tc.verifyFalse(r.verdict, sprintf( ...
                    'an aborted frame passed the FCS check at stallAt=%d', stallAt));
            end
        end

        function goodFcsWouldHavePassed(tc)
            % The control for the test above. If the un-inverted FCS did not
            % pass, the rejection would prove nothing about the inversion --
            % it could just mean abortedFrame builds a malformed frame.
            payload = uint8(mod(0:99, 251));
            f = gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, 60);

            repaired = [f.frameBytes(1:end-4), f.goodFcs];
            r = gem.parseFrame(repaired);

            tc.verifyTrue(r.verdict, ...
                'the aborted frame is malformed independently of its FCS');
        end

        function txErrorRidesTheFcsOctetsOnly(tc)
            % Decision 3. The abort is detected when the MAC runs dry and it
            % terminates immediately, so the four FCS octets are the whole
            % abort tail. Marking earlier octets would be marking data that
            % went out correctly.
            p = gem.params();
            payload = uint8(mod(0:99, 251));
            f = gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, 60);

            tc.verifyEqual(sum(f.er), p.FCS_BYTES);
            tc.verifyTrue(all(f.er(end - p.FCS_BYTES + 1 : end)));
            tc.verifyFalse(any(f.er(1 : end - p.FCS_BYTES)));
        end

        function txErrorEncodesAsDisagreeingControlEdges(tc)
            % B.4b item 4 says TX_ER is the RGMII mechanism already implemented
            % by gem.rgmiiEncode -- CTL high on the rising edge, low on the
            % falling. This checks the abort actually lands there rather than
            % inventing a second convention.
            p = gem.params();
            payload = uint8(mod(0:99, 251));
            f = gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, 60);
            cycles = gem.rgmiiEncode(f.packetBytes, true, f.er);

            fcsCycles = cycles(end - p.FCS_BYTES + 1 : end);
            ctlRise = bitand(bitshift(fcsCycles, -8), uint16(1));
            ctlFall = bitand(bitshift(fcsCycles, -9), uint16(1));

            tc.verifyEqual(ctlRise, ones(1, p.FCS_BYTES, 'uint16'), ...
                'TX_EN must stay asserted across the abort tail');
            tc.verifyEqual(ctlFall, zeros(1, p.FCS_BYTES, 'uint16'), ...
                'TX_ER must be asserted across the abort tail');
        end

        function stallBeyondPayloadIsRejected(tc)
            % The generator must not be able to ask for an abort that could not
            % happen -- a stall past the end of the payload is a frame that
            % completed, not one that underran.
            payload = uint8(mod(0:49, 251));
            tc.verifyError( ...
                @() gem.abortedFrame(payload, tc.DA, tc.SA, tc.ET, 60), ...
                'gem:stallBeyondPayload');
        end

        function scenarioSplitsCountersBetweenOkAndUnderrun(tc)
            % B.4b item 6: an aborted frame is not a transmitted frame. A MAC
            % that aborts correctly on the wire but still scores tx_ok would
            % pass a cycle diff and fail here.
            s = gem.genTxScenario('probe', NumFrames=12, ReadyMode='always', ...
                StallEvery=3, StallDepth=60, StallCycles=64);

            aborted = sum([s.records.expectAborted]);
            tc.verifyGreaterThan(aborted, 0, ...
                'the probe scenario produced no aborts, so it tests nothing');
            tc.verifyEqual(s.counters.tx_underrun, aborted);
            tc.verifyEqual(s.counters.tx_ok, numel(s.records) - aborted);
        end

        function abortedContentIsIndependentOfPipelineDepth(tc)
            % The property that lets this be a frozen vector at all. Whatever
            % the RTL's pipeline depth, it can only have sent octets the user
            % supplied -- so the expected wire output is a function of stallAt
            % alone. Expressed here as: building the same abort twice from
            % different-length payloads that agree up to the stall gives
            % identical wire output.
            short = uint8(mod(0:99,  251));
            long  = uint8(mod(0:999, 251));

            a = gem.abortedFrame(short, tc.DA, tc.SA, tc.ET, 60);
            b = gem.abortedFrame(long,  tc.DA, tc.SA, tc.ET, 60);

            tc.verifyEqual(a.packetBytes, b.packetBytes);
            tc.verifyEqual(a.er, b.er);
        end

    end
end

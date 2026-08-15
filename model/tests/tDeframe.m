classdef tDeframe < matlab.unittest.TestCase
    %TDEFRAME SFD hunting, garbage rejection and back-to-back recovery.
    %
    %   Covers R8, R11 and the recovery half of R10 at model level. The last
    %   test here is the one that matters most: it drives the 8-cycle gap the
    %   standard actually permits, rather than the 12 a polite transmitter
    %   emits.

    properties (Constant)
        DA = uint8([1 2 3 4 5 6])
        SA = uint8([7 8 9 10 11 12])
        ET = hex2dec('0800')
    end

    methods (Access = private)
        function f = frame(tc, len, varargin)
            f = gem.buildFrame(uint8(mod(0:len-1, 251)), tc.DA, tc.SA, tc.ET, varargin{:});
        end
    end

    methods (Test)

        function findsSfdAfterFullPreamble(tc)
            f = tc.frame(100);
            [b, dv, er] = gem.buildStream(struct('bytes', f.packetBytes));
            found = gem.deframe(b, dv, er);

            tc.verifyNumElements(found, 1);
            tc.verifyTrue(found(1).sfdFound);
            tc.verifyEqual(found(1).frameBytes, f.frameBytes);
        end

        function findsSfdWithNoPreambleAtAll(tc)
            % R8: "tolerate shortened/absent preamble down to SFD-only."
            % A deframer that skips a fixed eight octets works perfectly
            % against its own transmitter and fails against real switches.
            for preambleLen = 0:7
                f = tc.frame(100, PreambleBytes=preambleLen);
                [b, dv, er] = gem.buildStream(struct('bytes', f.packetBytes));
                found = gem.deframe(b, dv, er);

                tc.verifyNumElements(found, 1, ...
                    sprintf('preamble length %d', preambleLen));
                tc.verifyEqual(found(1).frameBytes, f.frameBytes, ...
                    sprintf('frame lost with preamble length %d', preambleLen));
            end
        end

        function ignoresInterFrameGarbage(tc)
            % R11: octets during the gap with DV low are "normal inter-frame"
            % (Table 35-2) and must be dropped silently -- not counted, not
            % flagged, not mistaken for the start of anything.
            f = tc.frame(100);
            item = struct('bytes', f.packetBytes, 'gapBefore', 12, ...
                          'gapData', uint8([1 2 3 hex2dec('D5') 5 6 7 8 9 10 11 12]));

            [b, dv, er] = gem.buildStream(item);
            found = gem.deframe(b, dv, er);

            % Note the 0xD5 planted in the gap: it must not trigger the hunter,
            % because the hunter only looks while DV is asserted.
            tc.verifyNumElements(found, 1);
            tc.verifyEqual(found(1).frameBytes, f.frameBytes);
        end

        function dvBurstWithoutSfdIsReportedNotSilentlyDropped(tc)
            % Returned with sfdFound false rather than skipped, so a test can
            % assert the garbage was seen and correctly discarded instead of
            % passing because nothing happened at all.
            item = struct('bytes', uint8([hex2dec('55') hex2dec('55') 1 2 3]));
            [b, dv, er] = gem.buildStream(item);
            found = gem.deframe(b, dv, er);

            tc.verifyNumElements(found, 1);
            tc.verifyFalse(found(1).sfdFound);
            tc.verifyEmpty(found(1).frameBytes);
        end

        function recoversAcrossTheMinimumLegalGap(tc)
            % The test this whole file exists for. Minimum-size frames with no
            % preamble, separated by the 8-byte gap that 802.3 Table 4-2 Note 3
            % permits at the receiver -- the tightest recovery case a compliant
            % link can present. See Documents/"Why RX Recovery Gets 8 Cycles,
            % Not 20.md".
            p = gem.params();
            nFrames = 8;

            frames(nFrames) = struct('frameBytes', []);
            items(nFrames)  = struct('bytes', [], 'gapBefore', []);
            for k = 1:nFrames
                f = tc.frame(46, PreambleBytes=0);
                frames(k).frameBytes = f.frameBytes;
                items(k).bytes = f.packetBytes;
                items(k).gapBefore = p.IFG_RX_MIN_BYTES;
            end

            [b, dv, er] = gem.buildStream(items);
            found = gem.deframe(b, dv, er);

            tc.verifyNumElements(found, nFrames);
            for k = 1:nFrames
                tc.verifyEqual(found(k).frameBytes, frames(k).frameBytes, ...
                    sprintf('frame %d of %d mangled at the minimum gap', k, nFrames));
                r = gem.parseFrame(found(k).frameBytes);
                tc.verifyEqual(r.class, 'ok', ...
                    sprintf('frame %d classified %s', k, r.class));
            end
        end

        function goodFrameSurvivesAfterABadOne(tc)
            % R10's real requirement is not that a bad frame is rejected -- it
            % is that the *next* frame is received intact. Model level cannot
            % prove the RTL recovers, but it can establish what the expected
            % output is when it does.
            p = gem.params();

            bad = tc.frame(100);
            badBytes = bad.frameBytes;
            badBytes(30) = bitxor(badBytes(30), uint8(1));
            badPacket = [uint8(p.SFD_OCTET), badBytes];

            good = tc.frame(100, PreambleBytes=0);

            items = struct( ...
                'bytes',     {badPacket, good.packetBytes}, ...
                'gapBefore', {p.IFG_BYTES, p.IFG_RX_MIN_BYTES});

            [b, dv, er] = gem.buildStream(items);
            found = gem.deframe(b, dv, er);

            tc.verifyNumElements(found, 2);
            tc.verifyEqual(gem.parseFrame(found(1).frameBytes).class, 'badfcs');
            tc.verifyEqual(gem.parseFrame(found(2).frameBytes).class, 'ok');
            tc.verifyEqual(found(2).frameBytes, good.frameBytes);
        end

        function rxErrorFlagsFollowTheFrame(tc)
            % RX_ER is carried per octet through the deframer so the classifier
            % can tell "error inside this frame" from "error in the gap".
            f = tc.frame(100);
            err = false(1, numel(f.packetBytes));
            err(end-10) = true;

            item = struct('bytes', f.packetBytes, 'er', err);
            [b, dv, er2] = gem.buildStream(item);
            found = gem.deframe(b, dv, er2);

            tc.verifyNumElements(found, 1);
            tc.verifyTrue(any(found(1).rxErr));
            tc.verifyEqual(numel(found(1).rxErr), numel(found(1).frameBytes));
            tc.verifyEqual(gem.parseFrame(found(1).frameBytes, ...
                RxErr=found(1).rxErr).class, 'rxer');
        end

    end
end

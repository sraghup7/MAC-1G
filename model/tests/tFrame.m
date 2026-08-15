classdef tFrame < matlab.unittest.TestCase
    %TFRAME Framing, padding, FCS placement and RX classification.
    %
    %   Covers R1-R4, R6 on the build side and R9/R10 on the parse side. Each
    %   test names the requirement it traces to so verification_plan.md can be
    %   generated from, and checked against, this file rather than maintained
    %   by hand alongside it.

    properties (Constant)
        DA = uint8([hex2dec('00') hex2dec('0A') hex2dec('35') 1 2 3])
        SA = uint8([hex2dec('DE') hex2dec('AD') hex2dec('BE') hex2dec('EF') 0 1])
        ET = hex2dec('0800')   % IPv4, a Type-interpreted value (>= 1536)
    end

    methods (Test)

        % ---- Transmit side -------------------------------------------------

        function fieldOrderAndLengths(tc)
            % R1: preamble, SFD, DA, SA, EtherType, payload, FCS.
            p = gem.params();
            payload = uint8(1:100);
            f = gem.buildFrame(payload, tc.DA, tc.SA, tc.ET);

            tc.verifyEqual(f.packetBytes(1:p.PREAMBLE_BYTES), ...
                repmat(uint8(p.PREAMBLE_OCTET), 1, p.PREAMBLE_BYTES));
            tc.verifyEqual(f.packetBytes(p.PREAMBLE_BYTES + 1), uint8(p.SFD_OCTET));
            tc.verifyEqual(f.frameBytes(1:6),  tc.DA);
            tc.verifyEqual(f.frameBytes(7:12), tc.SA);
            tc.verifyEqual(numel(f.frameBytes), 14 + 100 + 4);
        end

        function etherTypeIsBigEndian(tc)
            % Clause 3.2.6: Length/Type ships high-order octet first -- the one
            % field that is big-endian at octet granularity. Easy to get wrong
            % because every octet is still LSB-bit-first on the wire.
            f = gem.buildFrame(uint8(1:60), tc.DA, tc.SA, hex2dec('88F7'));
            tc.verifyEqual(f.frameBytes(13), uint8(hex2dec('88')));
            tc.verifyEqual(f.frameBytes(14), uint8(hex2dec('F7')));
        end

        function fcsIsLeastSignificantOctetFirst(tc)
            % R4 / Clause 3.2.9. Reversing these four octets is the classic
            % Ethernet CRC bug: both directions break and neither points at
            % the cause.
            f = gem.buildFrame(uint8(1:100), tc.DA, tc.SA, tc.ET);
            crc = gem.crc32(f.frameBytes(1:end-4));

            tc.verifyEqual(f.frameBytes(end-3), uint8(bitand(crc, uint32(255))));
            tc.verifyEqual(f.frameBytes(end),   uint8(bitshift(crc, -24)));
            tc.verifyEqual(f.frameBytes(end-3:end), gem.fcsBytes(crc));
        end

        function fcsCoversHeaderAndPadOnly(tc)
            % The FCS protects DA..Pad. Preamble and SFD are part of the
            % packet, not the frame (Clause 3.1), and must not be included --
            % a model that CRCs from the preamble agrees with nothing.
            f = gem.buildFrame(uint8(1:100), tc.DA, tc.SA, tc.ET);
            tc.verifyTrue(gem.fcsResidue(f.frameBytes));
            tc.verifyFalse(gem.fcsResidue(f.packetBytes));
        end

        function paddingReachesMinimumFrame(tc)
            % R3 / Clause 3.2.8. Sweep across the boundary rather than testing
            % one value either side of it.
            p = gem.params();
            for len = [0 1 20 44 45 46 47 60]
                f = gem.buildFrame(uint8(zeros(1, len)), tc.DA, tc.SA, tc.ET);
                expectedPad = max(0, p.MIN_PAYLOAD_BYTES - len);

                tc.verifyEqual(f.padBytes, expectedPad, ...
                    sprintf('wrong pad for payload length %d', len));
                tc.verifyGreaterThanOrEqual(numel(f.frameBytes), p.MIN_FRAME_BYTES, ...
                    sprintf('frame under minimum for payload length %d', len));
            end
        end

        function padIsZeros(tc)
            % Content is unspecified by the standard; zeros are what the RTL
            % pad generator will emit, so the model must match bit for bit.
            f = gem.buildFrame(uint8([1 2 3]), tc.DA, tc.SA, tc.ET);
            padRegion = f.frameBytes(14 + 3 + 1 : end - 4);
            tc.verifyEqual(padRegion, zeros(1, 43, 'uint8'));
        end

        function maximumPayloadIsAccepted(tc)
            p = gem.params();
            f = gem.buildFrame(uint8(zeros(1, p.MAX_PAYLOAD_BYTES)), ...
                tc.DA, tc.SA, tc.ET);
            tc.verifyEqual(numel(f.frameBytes), p.MAX_FRAME_BYTES);
            tc.verifyEqual(f.padBytes, 0);
        end

        function oversizePayloadIsRejected(tc)
            % R6: reject, never truncate. A truncated frame is a valid-looking
            % frame carrying wrong data, which is worse than no frame.
            p = gem.params();
            tc.verifyError( ...
                @() gem.buildFrame(uint8(zeros(1, p.MAX_PAYLOAD_BYTES + 1)), ...
                                   tc.DA, tc.SA, tc.ET), ...
                'gem:payloadTooLong');
        end

        function preambleCanBeTrimmed(tc)
            % R8's counterpart on the generator side: to test that RX copes
            % with a trimmed preamble, the model must be able to produce one.
            f = gem.buildFrame(uint8(1:60), tc.DA, tc.SA, tc.ET, PreambleBytes=0);
            tc.verifyEqual(f.packetBytes(1), uint8(hex2dec('D5')));
            tc.verifyEqual(numel(f.packetBytes), numel(f.frameBytes) + 1);
        end

        % ---- Receive side --------------------------------------------------

        function goodFrameParsesClean(tc)
            % R9: verdict true, header recovered.
            f = gem.buildFrame(uint8(1:100), tc.DA, tc.SA, tc.ET);
            r = gem.parseFrame(f.frameBytes);

            tc.verifyEqual(r.class, 'ok');
            tc.verifyTrue(r.verdict);
            tc.verifyEqual(r.da, tc.DA);
            tc.verifyEqual(r.sa, tc.SA);
            tc.verifyEqual(r.etherType, tc.ET);
            tc.verifyEqual(r.payload, uint8(1:100));
        end

        function padIsNotStripped(tc)
            % The documented decision in GEM.PARSEFRAME. With a Type-
            % interpreted Length/Type field there is no length to strip pad
            % against (Clause 3.2.6), and the client owns the problem. A
            % 20-octet payload arriving as 46 is correct behaviour, and the
            % RTL must match it.
            p = gem.params();
            f = gem.buildFrame(uint8(1:20), tc.DA, tc.SA, tc.ET);
            r = gem.parseFrame(f.frameBytes);

            tc.verifyEqual(numel(r.payload), p.MIN_PAYLOAD_BYTES);
            tc.verifyEqual(r.payload(1:20), uint8(1:20));
            tc.verifyEqual(r.payload(21:end), zeros(1, 26, 'uint8'));
        end

        function classifiesBadFcs(tc)
            % R10.
            f = gem.buildFrame(uint8(1:100), tc.DA, tc.SA, tc.ET);
            corrupted = f.frameBytes;
            corrupted(50) = bitxor(corrupted(50), uint8(1));

            r = gem.parseFrame(corrupted);
            tc.verifyEqual(r.class, 'badfcs');
            tc.verifyFalse(r.verdict);
        end

        function classifiesRunt(tc)
            % R10. 63 octets: one below minFrameSize.
            r = gem.parseFrame(uint8(zeros(1, 63)));
            tc.verifyEqual(r.class, 'runt');
            tc.verifyFalse(r.verdict);
        end

        function classifiesOversize(tc)
            % R10. 1519 octets: one above maxBasicFrameSize.
            p = gem.params();
            r = gem.parseFrame(uint8(zeros(1, p.MAX_FRAME_BYTES + 1)));
            tc.verifyEqual(r.class, 'oversize');
        end

        function classifiesRxError(tc)
            % R10. RX_ER asserted anywhere in the frame invalidates it even
            % though the FCS is perfect -- the PHY has said the bits are not
            % to be trusted.
            f = gem.buildFrame(uint8(1:100), tc.DA, tc.SA, tc.ET);
            err = false(1, numel(f.frameBytes));
            err(40) = true;

            r = gem.parseFrame(f.frameBytes, RxErr=err);
            tc.verifyEqual(r.class, 'rxer');
            tc.verifyFalse(r.verdict);
            tc.verifyTrue(r.fcsGood);   % the FCS really was fine
        end

        function classPrecedenceIsRuntOverBadFcs(tc)
            % The ambiguity GEM.PARSEFRAME had to resolve. A truncated frame
            % is both a runt and an FCS failure; scoring it as badfcs would
            % leave the runt counter permanently at zero, which is the merged-
            % counter outcome R17 exists to avoid.
            f = gem.buildFrame(uint8(1:100), tc.DA, tc.SA, tc.ET);
            truncated = f.frameBytes(1:40);

            r = gem.parseFrame(truncated);
            tc.verifyFalse(r.fcsGood, 'test premise: truncation should break the FCS');
            tc.verifyEqual(r.class, 'runt');
        end

        function classPrecedenceIsRxErOverEverything(tc)
            % rxer outranks runt: the length was measured from bits the PHY
            % told us to distrust.
            err = true(1, 30);
            r = gem.parseFrame(uint8(zeros(1, 30)), RxErr=err);
            tc.verifyEqual(r.class, 'rxer');
        end

        function roundTripAcrossLengthSweep(tc)
            % R1-R4 and R9 together, over the boundary set from B.4 plus a
            % coarse sweep. Any payload in must come back out identically with
            % a good verdict.
            lengths = unique([1:7:1500, 45, 46, 47, 63, 64, 65, 1499, 1500]);
            for len = lengths
                payload = uint8(mod(0:len-1, 251));
                f = gem.buildFrame(payload, tc.DA, tc.SA, tc.ET);
                r = gem.parseFrame(f.frameBytes);

                tc.verifyEqual(r.class, 'ok', ...
                    sprintf('length %d did not round trip clean', len));
                tc.verifyEqual(r.payload(1:len), payload, ...
                    sprintf('payload corrupted at length %d', len));
            end
        end

    end
end

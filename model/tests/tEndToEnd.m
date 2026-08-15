classdef tEndToEnd < matlab.unittest.TestCase
    %TENDTOEND The model closed on itself, through the RGMII pin encoding.
    %
    %   Every earlier test checks one stage. This one runs the full chain:
    %
    %       buildFrame -> buildStream -> rgmiiEncode
    %                  -> rgmiiDecode -> deframe -> parseFrame
    %
    %   which is the same path a vector file takes to the DUT and back. If
    %   this passes, a mismatch in simulation is the RTL's fault -- which is
    %   the entire reason for building the model before the hardware.
    %
    %   It is not a proof of correctness on its own: encoder and decoder could
    %   be inverse and both wrong. That risk is what tCrc32's external
    %   cross-check and tRgmii's edge-mapping tests cover.

    properties (Constant)
        DA = uint8([hex2dec('00') hex2dec('0A') hex2dec('35') 1 2 3])
        SA = uint8([hex2dec('DE') hex2dec('AD') hex2dec('BE') hex2dec('EF') 0 1])
        ET = hex2dec('0800')
    end

    methods (Test)

        function lengthSweepSurvivesTheWholeChain(tc)
            lengths = unique([1, 45, 46, 47, 63, 64, 65, 100:97:1400, 1499, 1500]);

            for len = lengths
                payload = uint8(mod(0:len-1, 251));
                f = gem.buildFrame(payload, tc.DA, tc.SA, tc.ET);

                [b, dv, er] = gem.buildStream(struct('bytes', f.packetBytes));
                cycles = gem.rgmiiEncode(b, dv, er);
                [b2, dv2, er2] = gem.rgmiiDecode(cycles);
                found = gem.deframe(b2, dv2, er2);

                tc.assertNumElements(found, 1, ...
                    sprintf('length %d: expected exactly one frame', len));

                r = gem.parseFrame(found(1).frameBytes, RxErr=found(1).rxErr);
                tc.verifyEqual(r.class, 'ok', ...
                    sprintf('length %d classified %s', len, r.class));
                tc.verifyEqual(r.payload(1:len), payload, ...
                    sprintf('length %d: payload corrupted in transit', len));
                tc.verifyEqual(r.da, tc.DA);
                tc.verifyEqual(r.sa, tc.SA);
            end
        end

        function mixedTrafficWithCorruptionAndTightGaps(tc)
            % A single stream carrying every error class, minimum-size frames,
            % trimmed preambles and gaps at the 8-cycle floor -- i.e. the shape
            % of the real regression, run once here so the composition is
            % proven before the generator starts producing thousands of them.
            p = gem.params();

            expectedClasses = {'ok', 'badfcs', 'ok', 'runt', 'ok', 'rxer', 'ok'};
            items = struct('bytes', {}, 'gapBefore', {}, 'er', {});

            for k = 1:numel(expectedClasses)
                f = gem.buildFrame(uint8(mod(0:99, 251)), tc.DA, tc.SA, tc.ET, ...
                    PreambleBytes=mod(k, 8));
                packet = f.packetBytes;
                err = false(1, numel(packet));

                switch expectedClasses{k}
                    case 'badfcs'
                        packet(end-20) = bitxor(packet(end-20), uint8(hex2dec('80')));
                    case 'runt'
                        % Keep SFD plus 40 octets: too short to be legal.
                        sfdAt = find(packet == uint8(p.SFD_OCTET), 1);
                        packet = packet(1:sfdAt+40);
                        err = false(1, numel(packet));
                    case 'rxer'
                        err(end-30) = true;
                end

                items(end+1) = struct('bytes', packet, ...
                    'gapBefore', p.IFG_RX_MIN_BYTES, 'er', err); %#ok<AGROW>
            end

            [b, dv, er] = gem.buildStream(items);
            found = gem.deframe(b, dv, er);

            tc.assertNumElements(found, numel(expectedClasses), ...
                'deframer did not recover one frame per transmitted frame');

            for k = 1:numel(expectedClasses)
                r = gem.parseFrame(found(k).frameBytes, RxErr=found(k).rxErr);
                tc.verifyEqual(r.class, expectedClasses{k}, sprintf( ...
                    'frame %d: expected %s, got %s (length %d, fcsGood %d)', ...
                    k, expectedClasses{k}, r.class, r.lengthBytes, r.fcsGood));
            end
        end

    end
end

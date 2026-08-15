classdef tRgmii < matlab.unittest.TestCase
    %TRGMII The RGMII double-data-rate encoding (R13, R14 timing aside).
    %
    %   These are small tests guarding details that are invisible in
    %   simulation until they are wrong on the bench: which nibble rides which
    %   clock edge, and how RX_ER is carried on a bus with no RX_ER pin.

    methods (Test)

        function lowNibbleOnRisingEdge(tc)
            % RGMII v2.0: data[3:0] on the rising edge, data[7:4] on the
            % falling. Swapping them gives a design that transmits every octet
            % nibble-reversed -- and since it also *receives* them reversed,
            % an internal loopback test passes happily.
            word = gem.rgmiiEncode(uint8(hex2dec('A5')), true, false);

            tc.verifyEqual(bitand(word, uint16(15)),            uint16(5));  % rise
            tc.verifyEqual(bitand(bitshift(word,-4), uint16(15)), uint16(10)); % fall
        end

        function idleIsAllZero(tc)
            % DV low, ER low: CTL low on both edges. This is the encoding the
            % RX path spends most of its life looking at.
            tc.verifyEqual(gem.rgmiiEncode(uint8(0), false, false), uint16(0));
        end

        function controlEncodingTable(tc)
            % CTL rising = DV, CTL falling = DV XOR ER (Table 35-2 carried onto
            % RGMII's two-edge control). Getting this XOR backwards yields a
            % MAC that handles clean traffic perfectly and never reports an
            % error -- a bug that survives to the bench.
            ctl = @(w) [bitand(bitshift(w,-8), uint16(1)), ...
                        bitand(bitshift(w,-9), uint16(1))];

            tc.verifyEqual(ctl(gem.rgmiiEncode(uint8(0), false, false)), uint16([0 0]));
            tc.verifyEqual(ctl(gem.rgmiiEncode(uint8(0), true,  false)), uint16([1 1]));
            tc.verifyEqual(ctl(gem.rgmiiEncode(uint8(0), true,  true )), uint16([1 0]));
            tc.verifyEqual(ctl(gem.rgmiiEncode(uint8(0), false, true )), uint16([0 1]));
        end

        function encodeDecodeRoundTrip(tc)
            % The encoder and decoder must not be wrong in the same direction.
            % Random streams with random qualifiers, checked all three ways.
            rng(20260814);
            for trial = 1:200
                n = randi([1 300]);
                bytes = uint8(randi([0 255], 1, n));
                dv    = logical(randi([0 1], 1, n));
                er    = logical(randi([0 1], 1, n));

                [b2, dv2, er2] = gem.rgmiiDecode(gem.rgmiiEncode(bytes, dv, er));

                tc.verifyEqual(b2,  bytes, sprintf('bytes differ, trial %d', trial));
                tc.verifyEqual(dv2, dv,    sprintf('dv differs, trial %d', trial));
                tc.verifyEqual(er2, er,    sprintf('er differs, trial %d', trial));
            end
        end

        function wordFitsTwelveBits(tc)
            % The vector files carry three hex characters per cycle. If a word
            % ever exceeded 12 bits the files would silently truncate.
            rng(1);
            bytes = uint8(randi([0 255], 1, 1000));
            words = gem.rgmiiEncode(bytes, true(1,1000), true(1,1000));
            tc.verifyLessThan(max(words), uint16(4096));
        end

        function qualifierLengthIsChecked(tc)
            tc.verifyError(@() gem.rgmiiEncode(uint8(1:10), true(1,5), false), ...
                'gem:qualifierLength');
        end

    end
end

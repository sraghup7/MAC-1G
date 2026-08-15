classdef tCrc32 < matlab.unittest.TestCase
    %TCRC32 Validation of the golden model's FCS against outside references.
    %
    %   The whole verification strategy rests on this function being exactly
    %   right, so it is not checked against itself. Three independent anchors:
    %
    %     1. The published check value for CRC-32/ISO-HDLC. A number from the
    %        standard's own documentation, not from this codebase.
    %     2. Python's zlib.crc32 -- a separate implementation by separate
    %        authors, compared over thousands of random vectors. Agreement on
    %        one vector is luck; agreement on 2000 of random length is not.
    %     3. The residue property, which is a structural consequence of the
    %        algorithm rather than a value anyone typed in.
    %
    %   Failing any of these means every downstream test result is worthless,
    %   which is why they run first.

    methods (Test)

        function checkValue(tc)
            % The canonical CRC-32/ISO-HDLC check value: the CRC of the ASCII
            % string "123456789". Quoted in Documents/IEEE802.3-2022_notes_
            % for_1G_MAC.md and in every CRC catalogue.
            tc.verifyEqual(gem.crc32('123456789'), uint32(hex2dec('CBF43926')));
        end

        function emptyInput(tc)
            % With init 0xFFFFFFFF and a final complement, zero bytes of input
            % must come back to zero. A model that returns 0xFFFFFFFF here has
            % dropped the final XOR.
            tc.verifyEqual(gem.crc32(uint8([])), uint32(0));
        end

        function tableIsDerivedCorrectly(tc)
            % Spot-check the byte-parallel table against the classic reflected
            % CRC-32 table. These entries appear in every published
            % implementation, so they are an outside reference too.
            tbl = gem.crc32Table();
            tc.verifySize(tbl, [1 256]);
            tc.verifyEqual(tbl(1),   uint32(hex2dec('00000000')));
            tc.verifyEqual(tbl(2),   uint32(hex2dec('77073096')));
            tc.verifyEqual(tbl(3),   uint32(hex2dec('EE0E612C')));
            tc.verifyEqual(tbl(256), uint32(hex2dec('2D02EF8D')));
        end

        function incrementalMatchesWhole(tc)
            % The hardware accumulates one byte per cycle and never has the
            % whole frame in hand, so the model must support the same. If the
            % resume path is wrong, every mid-frame accumulator check in the
            % testbench compares against a fiction.
            rng(20260814);
            for trial = 1:200
                a = uint8(randi([0 255], 1, randi([0 40])));
                b = uint8(randi([0 255], 1, randi([1 40])));
                tc.verifyEqual(gem.crc32(b, gem.crc32(a)), gem.crc32([a b]), ...
                    sprintf('incremental mismatch on trial %d', trial));
            end
        end

        function agreesWithZlib(tc)
            % Cross-check against an independent implementation. Vectors are
            % generated here, written out, and CRC'd by Python; a disagreement
            % reports the offending vector's index and length, not just a
            % count, so it can be reproduced immediately.
            nVectors = 2000;
            rng(20260814);

            lengths = randi([0 300], 1, nVectors);
            vectors = cell(1, nVectors);
            mine    = zeros(1, nVectors, 'uint32');
            for k = 1:nVectors
                vectors{k} = uint8(randi([0 255], 1, lengths(k)));
                mine(k) = gem.crc32(vectors{k});
            end

            theirs = gem.crc32Reference(vectors);

            tc.assumeNotEmpty(theirs, ...
                'Python/zlib unavailable -- external CRC cross-check skipped.');

            bad = find(mine ~= theirs);
            if isempty(bad)
                tc.verifyTrue(true);
                return
            end

            first = bad(1);
            tc.verifyFail(sprintf( ...
                ['CRC disagrees with zlib on %d of %d vectors. ' ...
                 'First at index %d (length %d): model 0x%08X, zlib 0x%08X.'], ...
                numel(bad), nVectors, first, lengths(first), ...
                mine(first), theirs(first)));
        end

        function residueIsConstant(tc)
            % Run the CRC across a frame *including* its own FCS and the same
            % constant must fall out every time, for any content and any
            % length. This is the property the RX path's single comparator
            % relies on (R9) -- see GEM.FCSRESIDUE.
            p = gem.params();
            rng(20260814);

            residues = zeros(1, 500, 'uint32');
            for k = 1:500
                data = uint8(randi([0 255], 1, randi([1 400])));
                withFcs = [data, gem.fcsBytes(gem.crc32(data))];
                residues(k) = gem.crc32(withFcs);
            end

            tc.verifyEqual(unique(residues), uint32(p.CRC32_RESIDUE), ...
                'Residue is not the constant declared in gem_mac_params.vh.');
        end

        function residueRejectsCorruption(tc)
            % The residue must actually discriminate. Flip one bit anywhere in
            % a frame and the check has to fail -- otherwise every bad-FCS test
            % downstream is passing for the wrong reason.
            rng(20260814);
            for trial = 1:200
                data = uint8(randi([0 255], 1, randi([46 200])));
                frame = [data, gem.fcsBytes(gem.crc32(data))];

                pos = randi(numel(frame));
                bit = randi([0 7]);
                frame(pos) = bitxor(frame(pos), uint8(2^bit));

                tc.verifyFalse(gem.fcsResidue(frame), sprintf( ...
                    'Corrupted frame passed the FCS check (trial %d, octet %d, bit %d).', ...
                    trial, pos, bit));
            end
        end

        function rejectsNonBytes(tc)
            % Silent saturation on a bad input would let a generator bug turn
            % into a "model and RTL disagree" mystery. Fail loudly instead.
            tc.verifyError(@() gem.crc32([0 255 256]), 'gem:notByte');
            tc.verifyError(@() gem.crc32([0 1.5]),     'gem:notInteger');
        end

    end
end

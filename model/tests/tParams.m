classdef tParams < matlab.unittest.TestCase
    %TPARAMS The model and the RTL must agree about every constant.
    %
    %   GEM.PARAMS parses rtl/gem_mac_params.vh rather than restating its
    %   values, which removes the possibility of drift -- but only if the
    %   parser itself is right. These tests check the parse against values
    %   traceable to IEEE 802.3-2022 and PROJECT_SPEC.md B.3a, and check the
    %   internal arithmetic of the header for self-consistency.
    %
    %   "Model and RTL disagree about a constant" is a bug that presents as a
    %   real RTL failure and costs a day. This file is the cheap insurance.

    methods (Test)

        function standardValues(tc)
            p = gem.params(true);

            % IEEE 802.3-2022 Clause 3 / Table 4-2.
            tc.verifyEqual(p.PREAMBLE_BYTES,   7);
            tc.verifyEqual(p.PREAMBLE_OCTET,   uint32(hex2dec('55')));
            tc.verifyEqual(p.SFD_OCTET,        uint32(hex2dec('D5')));
            tc.verifyEqual(p.MIN_FRAME_BYTES,  64);     % minFrameSize, 512 bits
            tc.verifyEqual(p.MAX_FRAME_BYTES,  1518);   % maxBasicFrameSize
            tc.verifyEqual(p.IFG_BYTES,        12);     % interPacketGap, 96 bits
            tc.verifyEqual(p.FCS_BYTES,        4);

            % Clause 3.2.9 CRC parameters.
            tc.verifyEqual(p.CRC32_POLY,    uint32(hex2dec('04C11DB7')));
            tc.verifyEqual(p.CRC32_INIT,    uint32(hex2dec('FFFFFFFF')));
            tc.verifyEqual(p.CRC32_XOROUT,  uint32(hex2dec('FFFFFFFF')));
        end

        function rxGapFloorIsEight(tc)
            % Not 12. Table 4-2 Note 3 lets the observed gap shrink to 64 bit
            % times, and R8 lets the preamble vanish, so RX recovery has 8
            % cycles. If this ever gets "corrected" to 12, the generator stops
            % exercising the tight case and the regression goes quietly blind.
            p = gem.params(true);
            tc.verifyEqual(p.IFG_RX_MIN_BYTES, 8);
            tc.verifyLessThan(p.IFG_RX_MIN_BYTES, p.IFG_BYTES);
        end

        function headerArithmeticIsConsistent(tc)
            % The payload bounds are not independent numbers -- they follow
            % from the frame bounds. Check the header's own arithmetic so a
            % hand edit to one line cannot leave the others stale.
            p = gem.params(true);

            tc.verifyEqual(p.HEADER_BYTES, ...
                p.DA_BYTES + p.SA_BYTES + p.ETHERTYPE_BYTES);

            tc.verifyEqual(p.MIN_PAYLOAD_BYTES, ...
                p.MIN_FRAME_BYTES - p.HEADER_BYTES - p.FCS_BYTES);

            tc.verifyEqual(p.MAX_PAYLOAD_BYTES, ...
                p.MAX_FRAME_BYTES - p.HEADER_BYTES - p.FCS_BYTES);
        end

        function fifoDepthMatchesAddressWidth(tc)
            p = gem.params(true);
            tc.verifyEqual(p.RX_FIFO_DEPTH, 2^p.RX_FIFO_ADDR_W, ...
                'RX_FIFO_DEPTH and RX_FIFO_ADDR_W have drifted apart.');
        end

        function cacheInvalidatesWhenTheHeaderChanges(tc)
            % gem.params caches, and the whole reason it exists is to stop the
            % model drifting from the RTL. A cache that never invalidates
            % reintroduces exactly that drift inside a single session: edit
            % gem_mac_params.vh, re-run, and silently get the old constants.
            %
            % The header is genuinely modified and restored via onCleanup, so
            % an assertion failure here cannot leave the file dirty.
            headerFile = fullfile(gem.repoRoot(), 'rtl', 'gem_mac_params.vh');
            original = fileread(headerFile);
            restore = onCleanup(@() writeText(headerFile, original));

            before = gem.params();
            tc.verifyFalse(isfield(before, 'CACHE_PROBE'), ...
                'GEM_CACHE_PROBE already exists; this test would prove nothing');

            writeText(headerFile, [original newline '`define GEM_CACHE_PROBE 4242' newline]);

            % The stamp is (datenum, bytes); the size changed, so this does not
            % depend on filesystem timestamp granularity.
            after = gem.params();
            tc.verifyTrue(isfield(after, 'CACHE_PROBE'), ...
                'gem.params returned stale constants after the header changed');
            tc.verifyEqual(double(after.CACHE_PROBE), 4242);

            clear restore    %#ok<CLEAR> -- restore now, then confirm it took
            tc.verifyFalse(isfield(gem.params(), 'CACHE_PROBE'), ...
                'gem.params did not pick the restored header back up');
        end

        function macroReferenceResolves(tc)
            % GEM_SIM_SCALE is defined as `GEM_MAX_PAYLOAD_BYTES, i.e. by
            % reference. The parser has to follow that, not store the literal
            % backtick text.
            p = gem.params(true);
            tc.verifyEqual(p.SIM_SCALE, p.MAX_PAYLOAD_BYTES);
            tc.verifyClass(p.SIM_SCALE, 'double');
        end

        function duplicateDefineIsRefused(tc)
            % The Verilog preprocessor resolves a duplicated `define
            % last-one-wins; this parser must refuse rather than guess,
            % because "which one did the author mean" is exactly the silent
            % disagreement between model and RTL that gem.params exists to
            % prevent. Same mutate-and-restore pattern as the cache test.
            headerFile = fullfile(gem.repoRoot(), 'rtl', 'gem_mac_params.vh');
            original = fileread(headerFile);
            restore = onCleanup(@() writeText(headerFile, original));

            writeText(headerFile, [original newline ...
                '`define GEM_IFG_BYTES 12' newline]);

            tc.verifyError(@() gem.params(), 'gem:paramsDuplicate');
        end

        function oversizedLiteralIsRefused(tc)
            % The RTL truncates an oversized literal to its declared width
            % without complaint -- 8'h1D5 is 8'hD5 to every Verilog tool --
            % so a parser that kept all three nibbles would disagree with
            % the hardware silently. The parser refuses instead; this pins
            % that refusal down.
            headerFile = fullfile(gem.repoRoot(), 'rtl', 'gem_mac_params.vh');
            original = fileread(headerFile);
            restore = onCleanup(@() writeText(headerFile, original));

            writeText(headerFile, [original newline ...
                '`define GEM_WIDTH_PROBE 8''h1D5' newline]);

            tc.verifyError(@() gem.params(), 'gem:paramsWidth');
        end

        function residueMatchesTheAlgorithm(tc)
            % The residue in the header is a claim about the CRC. Verify it
            % against the CRC itself rather than trusting the comment.
            p = gem.params(true);
            data = uint8(1:100);
            frame = [data, gem.fcsBytes(gem.crc32(data))];
            tc.verifyEqual(gem.crc32(frame), uint32(p.CRC32_RESIDUE));
        end

    end
end


function writeText(path, text)
%WRITETEXT Overwrite PATH with TEXT verbatim, no encoding surprises.
fid = fopen(path, 'w');
if fid < 0
    error('tParams:cannotWrite', 'Could not open %s for writing.', path);
end
c = onCleanup(@() fclose(fid));
fwrite(fid, text);
end

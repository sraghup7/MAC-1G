function tbl = crc32Table()
%CRC32TABLE 256-entry byte-parallel table for the IEEE 802.3 FCS.
%   TBL = GEM.CRC32TABLE() returns a 1-by-256 uint32 lookup table indexed by
%   (byteValue + 1). Entry k is the CRC register contribution of processing
%   one byte, which is exactly the combinational function the RTL implements
%   as an XOR tree (PROJECT_SPEC.md B.7 item 2: byte-parallel CRC, forced by
%   B.3's cycles-per-byte = 1.0 -- a bit-serial CRC needs 8 cycles per byte
%   and cannot keep up).
%
%   The table is derived from the polynomial in GEM.PARAMS, not hardcoded, so
%   there is exactly one place the polynomial is written down.
%
%   See also GEM.CRC32, GEM.PARAMS.

%   The table is built once and cached -- it is called per byte by GEM.CRC32
%   and rebuilding it 1500 times per frame dominates the runtime otherwise.
persistent cached
if ~isempty(cached)
    tbl = cached;
    return
end

p = gem.params();

% IEEE 802.3 feeds the CRC in transmission order, which is LSB-of-each-octet
% first (Clause 3.3). That is the "reflected input" convention, and the
% standard way to implement it is to run a right-shifting register against the
% bit-reversed polynomial rather than to reverse every input byte.
% reflect(0x04C11DB7) = 0xEDB88320.
polyReflected = reflectBits(uint32(p.CRC32_POLY), 32);

tbl = zeros(1, 256, 'uint32');
for value = 0:255
    reg = uint32(value);
    for bit = 1:8
        if bitand(reg, uint32(1))
            reg = bitxor(bitshift(reg, -1), polyReflected);
        else
            reg = bitshift(reg, -1);
        end
    end
    tbl(value + 1) = reg;
end

cached = tbl;
end


function out = reflectBits(value, nbits)
%REFLECTBITS Reverse the bit order of VALUE within NBITS.
out = uint32(0);
for k = 0:(nbits - 1)
    if bitand(bitshift(value, -k), uint32(1))
        out = bitset(out, nbits - k);
    end
end
end

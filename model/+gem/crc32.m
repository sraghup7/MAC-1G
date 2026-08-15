function crc = crc32(bytes, initial)
%CRC32 IEEE 802.3 frame check sequence over a byte vector.
%   CRC = GEM.CRC32(BYTES) returns the uint32 CRC-32 of BYTES using the
%   parameters of IEEE 802.3-2022 Clause 3.2.9:
%
%       polynomial  0x04C11DB7
%       init        0xFFFFFFFF   ("complement the first 32 bits of the frame")
%       reflect in  true         (Clause 3.3: octets ship LSB first)
%       reflect out true
%       final XOR   0xFFFFFFFF   (step (e): "complement the remainder")
%
%   CRC = GEM.CRC32(BYTES, INITIAL) resumes from a previous result, so that
%   GEM.CRC32([A B]) equals GEM.CRC32(B, GEM.CRC32(A)). This makes the model
%   streamable the same way the hardware is -- one byte per cycle, no need to
%   hold the whole frame -- and lets a testbench check the CRC accumulator
%   mid-frame rather than only at EOF.
%
%   Everything here is integer-exact uint32. That is the point of a golden
%   model: one that "basically agrees" catches nothing.
%
%   Two independent checks live in model/tests/tCrc32.m -- the standard check
%   value 0xCBF43926 for "123456789", and agreement with Python's zlib.crc32
%   over thousands of random vectors.
%
%   See also GEM.FCSBYTES, GEM.CRC32TABLE, GEM.PARAMS.

p = gem.params();
tbl = gem.crc32Table();

if nargin < 1 || isempty(bytes)
    bytes = uint8([]);
end
bytes = gem.mustBeByteVector(bytes, 'bytes');

if nargin < 2
    % Fresh frame: seed the register per step (a) of Clause 3.2.9.
    reg = uint32(p.CRC32_INIT);
else
    % Resume: INITIAL is a post-final-XOR value, so undo the complement to
    % recover the register state it came from.
    reg = bitxor(uint32(initial), uint32(p.CRC32_XOROUT));
end

for k = 1:numel(bytes)
    idx = bitand(bitxor(reg, uint32(bytes(k))), uint32(255));
    reg = bitxor(bitshift(reg, -8), tbl(double(idx) + 1));
end

crc = bitxor(reg, uint32(p.CRC32_XOROUT));
end

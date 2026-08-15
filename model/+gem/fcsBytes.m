function fcs = fcsBytes(crc)
%FCSBYTES CRC-32 word to the four FCS octets, in transmission order.
%   FCS = GEM.FCSBYTES(CRC) returns a 1-by-4 uint8 row vector: the FCS field
%   exactly as it goes onto the wire, first octet first.
%
%   This one line is the fiddliest rule in Clause 3, so it lives alone in its
%   own function where it can be tested in isolation.
%
%   Clause 3.3: "Each octet of the MAC frame, WITH THE EXCEPTION OF THE FCS,
%   is transmitted least significant bit first." Clause 3.2.9 then gives the
%   FCS its own rule -- the bits go out x^31 first. Once the reflected-output
%   CRC convention is applied (see GEM.CRC32), the net effect at octet
%   granularity is that the FCS ships **least-significant octet first**, which
%   is what R4 states and what this function implements.
%
%   Getting this backwards is the classic Ethernet CRC bug: every frame you
%   transmit is rejected by the far end, every frame you receive fails its
%   check, and both directions look equally broken so neither points at the
%   cause. GEM.FCSRESIDUE exists to catch it the moment it happens.
%
%   See also GEM.CRC32, GEM.FCSRESIDUE, GEM.BUILDFRAME.

crc = uint32(crc);

fcs = uint8([ ...
    bitand(            crc,      uint32(255)), ...
    bitand(bitshift(crc,  -8),   uint32(255)), ...
    bitand(bitshift(crc, -16),   uint32(255)), ...
    bitand(bitshift(crc, -24),   uint32(255))]);
end

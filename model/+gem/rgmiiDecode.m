function [bytes, dv, er] = rgmiiDecode(cycles)
%RGMIIDECODE Per-cycle RGMII words back to a GMII byte stream.
%   [BYTES, DV, ER] = GEM.RGMIIDECODE(CYCLES) is the exact inverse of
%   GEM.RGMIIENCODE. It is used two ways:
%
%     - to check the DUT's transmitted RGMII against the model, by decoding
%       what the bus functional model captured and comparing byte streams
%       rather than nibble timing;
%     - to close the model's own round trip (buildFrame -> encode -> decode ->
%       parseFrame), which is what proves the encoder and decoder are not
%       simply wrong in the same direction.
%
%   See also GEM.RGMIIENCODE.

cycles = uint16(cycles(:).');

lowNibble  = bitand(cycles, uint16(15));
highNibble = bitand(bitshift(cycles, -4), uint16(15));
ctlRise    = bitand(bitshift(cycles, -8), uint16(1));
ctlFall    = bitand(bitshift(cycles, -9), uint16(1));

bytes = uint8(lowNibble + bitshift(highNibble, 4));

% CTL rising edge carries DV directly; the falling edge carries DV XOR ER, so
% ER is recovered by XORing the two edges back together.
dv = logical(ctlRise);
er = xor(logical(ctlRise), logical(ctlFall));
end

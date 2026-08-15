function cycles = rgmiiEncode(bytes, dv, er)
%RGMIIENCODE GMII byte stream to per-cycle RGMII double-data-rate words.
%   CYCLES = GEM.RGMIIENCODE(BYTES, DV, ER) converts a byte stream and its
%   two qualifiers into one 12-bit word per clock cycle. BYTES, DV and ER are
%   equal-length vectors, one entry per byte-time -- which at 125 MHz is one
%   entry per clock cycle, because B.3's cycles-per-byte is exactly 1.0.
%
%   Idle is not a special case: it is simply a cycle with DV = false. That
%   makes inter-frame gap, inter-frame garbage (R11), RX_ER bursts (R10) and
%   frame data all the same kind of thing, so the generator can compose them
%   freely instead of the encoder needing to know about frames at all.
%
%   RGMII v2.0 mapping, per cycle:
%
%       rising  edge : data[3:0] (low nibble),  CTL = DV
%       falling edge : data[7:4] (high nibble), CTL = DV XOR ER
%
%   The falling-edge CTL encoding is why a legal idle cycle has CTL low on
%   both edges, and why RX_ER during a frame shows up as the two CTL edges
%   disagreeing -- not as a third pin. Getting this XOR backwards produces a
%   design that receives clean traffic perfectly and never reports an error,
%   which is the kind of bug that survives all the way to the bench.
%
%   Word layout (1 line per cycle in the emitted .hex vector files):
%
%       bit  9 : CTL on the falling edge  (DV XOR ER)
%       bit  8 : CTL on the rising edge   (DV)
%       bits 7:4 : data on the falling edge (high nibble)
%       bits 3:0 : data on the rising edge  (low nibble)
%
%   See also GEM.RGMIIDECODE, GEM.BUILDSTREAM.

if nargin < 2 || isempty(dv)
    dv = true(1, numel(bytes));
end
if nargin < 3 || isempty(er)
    er = false(1, numel(bytes));
end

bytes = gem.mustBeByteVector(bytes, 'bytes');
n = numel(bytes);

dv = expandQualifier(dv, n, 'dv');
er = expandQualifier(er, n, 'er');

lowNibble  = uint16(bitand(bytes, uint8(15)));
highNibble = uint16(bitshift(bytes, -4));

ctlRise = uint16(dv);
ctlFall = uint16(xor(dv, er));

cycles = lowNibble ...
       + bitshift(highNibble, 4) ...
       + bitshift(ctlRise,    8) ...
       + bitshift(ctlFall,    9);

cycles = uint16(cycles(:).');
end


function q = expandQualifier(q, n, name)
q = logical(q(:).');
if isscalar(q)
    q = repmat(q, 1, n);
elseif numel(q) ~= n
    error('gem:qualifierLength', ...
        '%s has %d entries but the stream is %d bytes.', name, numel(q), n);
end
end

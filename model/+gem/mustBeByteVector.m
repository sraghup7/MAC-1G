function out = mustBeByteVector(value, name)
%MUSTBEBYTEVECTOR Coerce VALUE to a uint8 row vector, or error clearly.
%   OUT = GEM.MUSTBEBYTEVECTOR(VALUE, NAME) accepts any numeric or char row/
%   column vector whose elements are integers in 0..255 and returns it as a
%   uint8 row vector. NAME appears in the error message.
%
%   This exists because MATLAB will silently saturate or round on a cast to
%   uint8, and a golden model that quietly turns 256 into 255 or 1.5 into 2 is
%   worse than one that crashes. Every entry point into the model funnels
%   through here so a bad vector is caught at the boundary, once, with the
%   offending value named.
%
%   See also GEM.CRC32, GEM.BUILDFRAME.

if ischar(value) || isstring(value)
    value = double(char(value));
end

if ~isnumeric(value) && ~islogical(value)
    error('gem:notNumeric', '%s must be numeric, char, or logical.', name);
end

value = double(value(:).');

if ~isempty(value)
    if any(~isfinite(value)) || any(value ~= floor(value))
        error('gem:notInteger', '%s must contain integer values only.', name);
    end
    bad = find(value < 0 | value > 255, 1);
    if ~isempty(bad)
        error('gem:notByte', ...
            '%s(%d) = %g is outside the byte range 0..255.', ...
            name, bad, value(bad));
    end
end

out = uint8(value);
end

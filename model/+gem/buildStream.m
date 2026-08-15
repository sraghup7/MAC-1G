function [bytes, dv, er] = buildStream(items, opts)
%BUILDSTREAM Compose packets, gaps and garbage into one RGMII byte stream.
%   [BYTES, DV, ER] = GEM.BUILDSTREAM(ITEMS) turns a struct array of things to
%   put on the wire into the three parallel vectors GEM.RGMIIENCODE consumes.
%   Each element of ITEMS may set:
%
%       .bytes      octets to send                      (required)
%       .gapBefore  idle cycles before it               (default: GEM_IFG_BYTES)
%       .dv         RX_DV during .bytes, scalar or per-octet   (default true)
%       .er         RX_ER during .bytes, scalar or per-octet   (default false)
%       .gapData    octet value(s) driven during the gap       (default 0)
%
%   Name-value options:
%       TrailingGap   idle cycles appended after the last item
%                     (default: GEM_IFG_BYTES)
%
%   .gapBefore is the knob that matters most and the one a naive generator
%   never varies. The transmit-side inter-frame gap is 12 byte-times (R5), but
%   what a *receiver* is entitled to assume is 8 -- 802.3 Table 4-2 Note 3
%   allows the observed gap to shrink to 64 bit-times through network delay
%   and clock tolerance, and R8 allows the preamble to be absent entirely.
%   See Documents/"Why RX Recovery Gets 8 Cycles, Not 20.md". A regression
%   that only ever emits 12 passes even when the RX recovery path silently
%   needs 15, and that bug then debuts on real hardware.
%
%   .gapData exists for R11: a gap carrying nonzero octets with DV low is
%   "normal inter-frame" per Table 35-2, and the RX path must ignore it
%   silently rather than treat it as the start of something.
%
%   See also GEM.RGMIIENCODE, GEM.DEFRAME, GEM.BUILDFRAME.

arguments
    items struct
    % [] rather than a sentinel: MATLAB validates argument defaults, so a -1
    % "unset" marker would trip mustBeNonnegative on every call.
    opts.TrailingGap {mustBeNumeric, mustBeNonnegative} = []
end

p = gem.params();

if isempty(opts.TrailingGap)
    trailingGap = p.IFG_BYTES;
else
    trailingGap = double(opts.TrailingGap);
end

bytes = uint8([]);
dv    = false(1, 0);
er    = false(1, 0);

for k = 1:numel(items)
    item = items(k);

    gapBefore = getFieldOr(item, 'gapBefore', p.IFG_BYTES);
    gapData   = getFieldOr(item, 'gapData',   0);
    itemBytes = gem.mustBeByteVector(getFieldOr(item, 'bytes', uint8([])), ...
                                     sprintf('items(%d).bytes', k));

    % --- gap ---
    gapBefore = double(gapBefore);
    if gapBefore > 0
        gapOctets = gem.mustBeByteVector(gapData, sprintf('items(%d).gapData', k));
        if isscalar(gapOctets)
            gapOctets = repmat(gapOctets, 1, gapBefore);
        elseif numel(gapOctets) ~= gapBefore
            error('gem:gapDataLength', ...
                'items(%d).gapData has %d octets but gapBefore is %d.', ...
                k, numel(gapOctets), gapBefore);
        end
        bytes = [bytes, gapOctets];              %#ok<AGROW>
        dv    = [dv,    false(1, gapBefore)];    %#ok<AGROW>
        er    = [er,    false(1, gapBefore)];    %#ok<AGROW>
    end

    % --- the item itself ---
    m = numel(itemBytes);
    bytes = [bytes, itemBytes];                                       %#ok<AGROW>
    dv    = [dv,    expand(getFieldOr(item, 'dv', true),  m, k, 'dv')]; %#ok<AGROW>
    er    = [er,    expand(getFieldOr(item, 'er', false), m, k, 'er')]; %#ok<AGROW>
end

if trailingGap > 0
    bytes = [bytes, zeros(1, trailingGap, 'uint8')];
    dv    = [dv,    false(1, trailingGap)];
    er    = [er,    false(1, trailingGap)];
end
end


function value = getFieldOr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end
end


function q = expand(q, n, idx, name)
q = logical(q(:).');
if isscalar(q)
    q = repmat(q, 1, n);
elseif numel(q) ~= n
    error('gem:qualifierLength', ...
        'items(%d).%s has %d entries but .bytes is %d octets.', ...
        idx, name, numel(q), n);
end
end

function frames = deframe(bytes, dv, er)
%DEFRAME Golden SFD hunter and deframer (R8, R11).
%   FRAMES = GEM.DEFRAME(BYTES, DV, ER) walks a received GMII byte stream and
%   returns a struct array, one entry per frame found:
%
%       .frameBytes  DA..FCS as received (preamble and SFD removed)
%       .rxErr       logical, one entry per octet of .frameBytes
%       .gapCycles   idle cycles since the previous frame ended
%       .startCycle  index of the first octet after the SFD
%       .sfdFound    false for a DV burst that never contained an SFD
%
%   Three rules from the spec are implemented here, and each one is a place
%   where the obvious implementation is wrong:
%
%   R8 -- the SFD is hunted for, not counted to. The hunter scans every octet
%   while DV is asserted and starts the frame at the first 0xD5, wherever it
%   falls. It does not assume seven octets of preamble, because senders trim
%   it: switches and cut-through forwarders are permitted to send anything
%   down to SFD-only. A deframer that skips eight octets and starts there
%   works perfectly against its own transmitter and fails against real ones.
%
%   R11 -- everything before that SFD is dropped silently. Not counted, not
%   flagged, not reported. Inter-frame garbage is normal on a real link.
%
%   A DV burst that ends without ever showing an SFD yields an entry with
%   .sfdFound false and no frame bytes; it is not an error, it is exactly what
%   R11 says to ignore. It is returned rather than skipped so a test can
%   assert that the garbage was seen and correctly discarded, instead of
%   passing because nothing happened for either the right or wrong reason.
%
%   See also GEM.PARSEFRAME, GEM.BUILDSTREAM, GEM.RGMIIDECODE.

p = gem.params();

bytes = gem.mustBeByteVector(bytes, 'bytes');
n = numel(bytes);
dv = logical(dv(:).');
er = logical(er(:).');
if numel(dv) ~= n || numel(er) ~= n
    error('gem:streamLength', ...
        'bytes/dv/er must be the same length (%d/%d/%d).', n, numel(dv), numel(er));
end

sfd = uint8(p.SFD_OCTET);

frames = struct('frameBytes', {}, 'rxErr', {}, 'gapCycles', {}, ...
                'startCycle', {}, 'sfdFound', {});

k = 1;
lastFrameEnd = 0;    % cycle index where the previous DV burst ended
while k <= n
    if ~dv(k)
        k = k + 1;
        continue
    end

    % A DV burst begins here. Find where it ends.
    burstStart = k;
    burstEnd = burstStart;
    while burstEnd < n && dv(burstEnd + 1)
        burstEnd = burstEnd + 1;
    end

    % Hunt for the SFD anywhere inside the burst (R8).
    sfdIdx = burstStart - 1 + find(bytes(burstStart:burstEnd) == sfd, 1);

    entry = struct( ...
        'frameBytes', uint8([]), ...
        'rxErr',      false(1, 0), ...
        'gapCycles',  burstStart - lastFrameEnd - 1, ...
        'startCycle', burstStart, ...
        'sfdFound',   false);

    if ~isempty(sfdIdx) && sfdIdx < burstEnd
        first = sfdIdx + 1;
        entry.frameBytes = bytes(first:burstEnd);
        entry.rxErr      = er(first:burstEnd);
        entry.startCycle = first;
        entry.sfdFound   = true;
    elseif ~isempty(sfdIdx)
        % SFD was the very last octet of the burst: a frame that started and
        % immediately stopped. Zero octets is a runt, and it must be reported
        % as one rather than silently dropped as garbage.
        entry.startCycle = sfdIdx + 1;
        entry.sfdFound   = true;
    end

    frames(end + 1) = entry; %#ok<AGROW>

    lastFrameEnd = burstEnd;
    k = burstEnd + 1;
end
end

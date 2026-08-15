function item = corrupt(frame, kind, offset)
%CORRUPT Apply one named corruption to one frame, at one location.
%   ITEM = GEM.CORRUPT(FRAME, KIND, OFFSET) takes a GEM.BUILDFRAME result and
%   returns a wire item ready for GEM.BUILDSTREAM:
%
%       .bytes          the (possibly damaged) packet octets
%       .er             per-octet RX_ER, logical
%       .kind           KIND, echoed back
%       .offset         where the damage was applied, in packet octets
%       .expectedClass  what GEM.PARSEFRAME should say, or '' (see below)
%
%   OFFSET is supplied by the caller rather than drawn here, so that the
%   seeded generator owns reproducibility completely -- one RNG, one place.
%   It is interpreted as a fraction-free index into the region each kind
%   damages, and is wrapped into range, so any integer is legal.
%
%   Kinds, and what each one is actually testing:
%
%     'none'      control. Also the majority of any realistic scenario -- a
%                 regression made entirely of broken frames never checks that
%                 good ones still work.
%     'badfcs'    one bit flipped inside the frame (R10). The FCS is the only
%                 thing that catches it, which is the point.
%     'badsfd'    the SFD octet damaged, so the frame is never framed (R8/R11).
%     'truncate'  frame cut short mid-flight -- a runt (R10), and the case that
%                 makes error-class precedence matter, since it breaks the FCS
%                 too.
%     'oversize'  octets appended past maxBasicFrameSize (R10). Detectable
%                 during reception rather than at the end, which is why it
%                 outranks runt and badfcs in GEM.PARSEFRAME.
%     'rxer'      RX_ER asserted for one octet inside the frame (R10). The FCS
%                 stays perfect: this tests that the PHY's opinion is honoured
%                 even when the data looks fine.
%
%   .expectedClass is '' for 'badsfd'. Damaging the SFD makes the outcome
%   depend on whether some later octet of the frame happens to be 0xD5 -- in
%   which case the hunter legitimately starts there and produces a garbage
%   frame of unpredictable class. That is correct behaviour under R8, so the
%   golden model is the only authority on the answer and the generator's
%   cross-check skips it rather than pretending to predict it.
%
%   See also GEM.BUILDFRAME, GEM.GENSCENARIO, GEM.BUILDSTREAM.

arguments
    frame  struct
    kind   (1,:) char
    offset (1,1) {mustBeNumeric} = 0
end

p = gem.params();

packet = frame.packetBytes;
er     = false(1, numel(packet));
sfdIdx = frame.preambleBytes + 1;      % index of the SFD octet in .packetBytes
frameStart = sfdIdx + 1;               % first octet of DA
frameLen   = numel(packet) - frameStart + 1;

expectedClass = 'ok';
appliedAt = 0;

switch lower(kind)

    case 'none'
        % nothing to do

    case 'badfcs'
        % Flip a single bit somewhere in DA..FCS. Confined to the frame proper
        % because damage to the preamble is a different test ('badsfd').
        appliedAt = frameStart + wrap(offset, frameLen);
        bit = wrap(offset, 8);
        packet(appliedAt) = bitxor(packet(appliedAt), uint8(2^bit));
        expectedClass = 'badfcs';

    case 'badsfd'
        % Corrupt the delimiter itself. Whatever the hunter then does is
        % R8-correct by construction, so the golden model decides.
        appliedAt = sfdIdx;
        packet(appliedAt) = bitxor(packet(appliedAt), uint8(hex2dec('40')));
        expectedClass = '';

    case 'truncate'
        % Keep the SFD and at least one octet after it, and stop short of the
        % legal minimum so the result really is a runt.
        keep = 1 + wrap(offset, p.MIN_FRAME_BYTES - 1);
        keep = min(keep, frameLen);
        packet = packet(1 : frameStart + keep - 1);
        er = false(1, numel(packet));
        appliedAt = frameStart + keep - 1;
        expectedClass = 'runt';

    case 'oversize'
        % Push the received frame past maxBasicFrameSize. The appended octets
        % also break the FCS, which is precisely why the precedence decision in
        % GEM.PARSEFRAME had to be made and written down.
        excess = 1 + wrap(offset, 64);
        needed = p.MAX_FRAME_BYTES - frameLen + excess;
        packet = [packet, uint8(mod(0:needed-1, 256))];
        er = false(1, numel(packet));
        appliedAt = numel(packet);
        expectedClass = 'oversize';

    case 'rxer'
        % One octet flagged by the PHY. Data untouched, FCS still valid.
        appliedAt = frameStart + wrap(offset, frameLen);
        er(appliedAt) = true;
        expectedClass = 'rxer';

    otherwise
        error('gem:unknownCorruption', ...
            'Unknown corruption kind "%s".', kind);
end

item = struct( ...
    'bytes',         packet, ...
    'er',            er, ...
    'dv',            true, ...
    'gapBefore',     p.IFG_BYTES, ...
    'gapData',       uint8(0), ...
    'kind',          kind, ...
    'offset',        appliedAt, ...
    'expectedClass', expectedClass);
end


function idx = wrap(offset, n)
%WRAP Fold any integer into 0..n-1, so no caller can pick an illegal offset.
if n <= 0
    idx = 0;
else
    idx = double(mod(floor(abs(offset)), n));
end
end

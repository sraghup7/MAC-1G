function result = parseFrame(frameBytes, opts)
%PARSEFRAME Golden RX path: a received frame to payload plus a verdict.
%   RESULT = GEM.PARSEFRAME(FRAMEBYTES) takes the octets from the first octet
%   after the SFD through the last octet before the gap -- i.e. DA..FCS as
%   received, preamble already stripped -- and returns:
%
%       .class     one of 'ok' | 'rxer' | 'oversize' | 'runt' | 'badfcs'
%       .verdict   true only for 'ok'; this is the R9 tuser bit at tlast
%       .payload   the delivered payload octets (see "Pad" below)
%       .da/.sa/.etherType   extracted header fields
%       .lengthBytes         received frame length, DA..FCS
%       .residue             the CRC residue actually reached
%
%   Name-value options:
%       RxErr   logical vector, one entry per received octet (or a scalar),
%               true where RGMII RX_ER was asserted during that octet (R10).
%
%   ---------------------------------------------------------------------
%   Two decisions this function had to make that the spec left open. Writing
%   the golden model is supposed to surface exactly these, and both are now
%   binding on the Stage 4 RTL.
%   ---------------------------------------------------------------------
%
%   1. ERROR CLASS PRECEDENCE. R10 names four error classes and requires "one
%      counter per class" (R17), but a single frame can be in several at once
%      -- a truncated frame is usually both a runt and an FCS failure. Without
%      a stated precedence, the model and the RTL will pick different ones and
%      every counter comparison will mismatch. The order used here, highest
%      first:
%
%         rxer > oversize > runt > badfcs
%
%      The reasoning is diagnostic value, which is the whole point of having
%      separate counters (see Documents/"Bad bitstream handle.md"):
%        - rxer first, because the PHY has said the bits are untrustworthy;
%          every classification below it is computed from those same bits, so
%          reporting one of them would be reporting a conclusion drawn from
%          data we were just told to distrust.
%        - oversize next: it is the only class detectable *during* reception
%          (the byte counter crosses 1518 mid-frame), so the hardware commits
%          to it before it can know anything about the FCS.
%        - runt above badfcs, because a runt nearly always fails its FCS too.
%          Scoring those as badfcs would leave the runt counter permanently at
%          zero and make the bad-FCS counter mean "something was wrong" -- the
%          exact merged-counter outcome R17 exists to avoid.
%
%   2. PAD IS NOT STRIPPED. With a Type-interpreted Length/Type field there is
%      no length in the frame to strip pad against (Clause 3.2.6), and Clause
%      3.2.6 puts the burden on the client: "the MAC client is responsible for
%      correctly handling whatever padding the MAC sublayer may have added."
%      So a 20-octet payload sent through this MAC arrives as 46 octets, and
%      that is correct, not a bug. Stripping would require the MAC to parse
%      layer 3, which is out of scope (B.7).
%
%   See also GEM.BUILDFRAME, GEM.FCSRESIDUE.

arguments
    frameBytes
    opts.RxErr = false
end

p = gem.params();
frameBytes = gem.mustBeByteVector(frameBytes, 'frameBytes');
n = numel(frameBytes);

rxErr = logical(opts.RxErr(:).');
if isscalar(rxErr)
    rxErr = repmat(rxErr, 1, n);
elseif numel(rxErr) ~= n
    error('gem:rxErrLength', ...
        'RxErr has %d entries but the frame is %d octets.', numel(rxErr), n);
end

% The residue check runs across the whole frame including its own FCS, which
% is what the hardware does -- see GEM.FCSRESIDUE for why that form and not a
% recompute-and-compare.
[fcsGood, residue] = gem.fcsResidue(frameBytes);

% Classification, in the precedence order argued above.
if any(rxErr)
    class = 'rxer';
elseif n > p.MAX_FRAME_BYTES
    class = 'oversize';
elseif n < p.MIN_FRAME_BYTES
    class = 'runt';
elseif ~fcsGood
    class = 'badfcs';
else
    class = 'ok';
end

% Header extraction is best-effort: a runt may be too short to hold one, and
% the RX path still has to report *something* rather than fault.
da = uint8([]); sa = uint8([]); etherType = NaN;
if n >= p.HEADER_BYTES
    da = frameBytes(1:p.DA_BYTES);
    sa = frameBytes(p.DA_BYTES + (1:p.SA_BYTES));
    etherType = double(frameBytes(13)) * 256 + double(frameBytes(14));
end

% Payload spans header..FCS exclusive, pad included (decision 2 above).
payload = uint8([]);
if n >= p.HEADER_BYTES + p.FCS_BYTES
    payload = frameBytes(p.HEADER_BYTES + 1 : n - p.FCS_BYTES);
end

result = struct( ...
    'class',       class, ...
    'verdict',     strcmp(class, 'ok'), ...
    'payload',     payload, ...
    'da',          da, ...
    'sa',          sa, ...
    'etherType',   etherType, ...
    'lengthBytes', n, ...
    'fcsGood',     fcsGood, ...
    'residue',     residue, ...
    'rxErr',       any(rxErr));
end

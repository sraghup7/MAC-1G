function s = genTxScenario(name, opts)
%GENTXSCENARIO Build a reproducible TX-direction stimulus scenario.
%   S = GEM.GENTXSCENARIO(NAME) returns the mirror of GEM.GENSCENARIO for the
%   transmit path: payloads and header fields go in, and the RGMII cycle
%   stream the MAC must produce comes out.
%
%   Options (name-value):
%       Seed         RNG seed. Default 20260814.
%       NumFrames    default 32.
%       Lengths      payload lengths to cycle through; default is B.4's
%                    boundary set plus ordinary sizes.
%       ReadyMode    'always' | 'gaps' | 'random' -- the tready profile.
%       MaxPayload   cap, default GEM_SIM_SCALE.
%       IncludeOversize  add one payload of 1501 octets, which the MAC must
%                        refuse to transmit (R6).
%       StallEvery   if > 0, every Nth frame stalls mid-payload and must be
%                    aborted per B.4b. Default 0 (no mid-frame stalls).
%       StallDepth   payload octet index at which the user stops supplying.
%       StallCycles  how long tvalid stays low.
%
%   TX is the easy direction and it is worth being clear about why: the MAC
%   owns the timing. It emits the full 7-octet preamble and the full 12-octet
%   inter-frame gap every time (R5), so unlike the RX path there is no
%   shrunken-gap case to survive -- gap shrinkage is something that happens to
%   a receiver, not something a compliant transmitter does to itself.
%
%   BACKPRESSURE. Gaps between frames come from ReadyMode. Stalls *inside* a
%   frame come from StallEvery, and they are a different thing entirely: an
%   inter-frame gap is something the MAC waits through, while a mid-frame stall
%   is an underrun the MAC cannot wait through, because RGMII has no pause once
%   TX_EN is high. Spec B.4b resolves it as cut-through with abort -- TX_ER plus
%   an inverted FCS, counted, never resumed -- and GEM.ABORTEDFRAME models the
%   result.
%
%   The stall parameters are chosen so the expected wire output is identical for
%   every conforming implementation, which is the only way this can be a frozen
%   vector at all. StallDepth sits well past the 22-octet head start B.4b grants
%   (preamble, SFD and header are MAC-generated, so a user that hesitates at SOF
%   is safe) and past the 46-octet padding boundary, so no implementation can
%   absorb the stall or pad its way out of it. StallCycles is far longer than any
%   plausible pipeline. Whether a MAC absorbs a *short* stall using its head
%   start is deliberately left unspecified and deliberately not tested here --
%   pinning it down would bake a pipeline depth into the frozen vectors.
%
%   See also GEM.GENSCENARIO, GEM.ABORTEDFRAME, GEM.BUILDFRAME.

arguments
    name (1,:) char
    opts.Seed        (1,1) {mustBeNumeric} = 20260814
    opts.NumFrames   (1,1) {mustBeNumeric, mustBePositive} = 32
    opts.Lengths           {mustBeNumeric} = []
    opts.ReadyMode   (1,:) char {mustBeMember(opts.ReadyMode, ...
                        {'always','gaps','random'})} = 'always'
    opts.MaxPayload        {mustBeNumeric} = []
    opts.IncludeOversize (1,1) logical = false
    opts.StallEvery  (1,1) {mustBeNumeric, mustBeNonnegative} = 0
    opts.StallDepth  (1,1) {mustBeNumeric, mustBePositive} = 60
    opts.StallCycles (1,1) {mustBeNumeric, mustBePositive} = 64
end

p = gem.params();

maxPayload = opts.MaxPayload;
if isempty(maxPayload)
    maxPayload = p.SIM_SCALE;
end

lengths = opts.Lengths;
if isempty(lengths)
    lengths = [1 45 46 47 63 64 65 100 512 1000 1499 1500];
end
lengths = min(double(lengths), maxPayload);

rng(opts.Seed, 'twister');

nFrames = double(opts.NumFrames);
lengthPick = lengths(1 + mod(0:nFrames-1, numel(lengths)));

da = uint8([hex2dec('00') hex2dec('0A') hex2dec('35') 1 2 3]);
sa = uint8([hex2dec('DE') hex2dec('AD') hex2dec('BE') hex2dec('EF') 0 1]);
etherType = hex2dec('0800');

records = struct('index', {}, 'payloadLen', {}, 'padBytes', {}, ...
                 'expectRejected', {}, 'expectAborted', {}, 'stallAt', {}, ...
                 'gapBefore', {}, 'readyGap', {});
items   = struct('bytes', {}, 'gapBefore', {}, 'er', {});
stim    = struct('index', {}, 'payload', {}, 'da', {}, 'sa', {}, ...
                 'etherType', {}, 'readyGap', {}, 'stallAt', {}, ...
                 'stallCycles', {});

% Stalls from ReadyMode sit between frames; StallEvery is what puts one inside.
switch opts.ReadyMode
    case 'always', readyGaps = zeros(1, nFrames);
    case 'gaps',   readyGaps = repmat(8, 1, nFrames);
    case 'random', readyGaps = randi([0 32], 1, nFrames);
end

stallEvery = double(opts.StallEvery);
stallDepth = double(opts.StallDepth);

emitted   = 0;
underruns = 0;
for k = 1:nFrames
    len = lengthPick(k);
    payload = uint8(mod((0:len-1) + k, 251));

    % A frame can only be aborted mid-payload if it has payload past the stall
    % depth. Short frames in the sweep transmit normally, which is what makes
    % this a mix rather than a monoculture -- the MAC has to get back to
    % transmitting cleanly after every abort, and R7 is about the recovery as
    % much as the abort.
    aborts = stallEvery > 0 && mod(k, stallEvery) == 0 && len > stallDepth;

    if aborts
        f = gem.abortedFrame(payload, da, sa, etherType, stallDepth);
        stallAt     = stallDepth;
        stallCycles = double(opts.StallCycles);
        padBytes    = 0;
        underruns   = underruns + 1;
    else
        f = gem.buildFrame(payload, da, sa, etherType);
        f.er        = false(1, numel(f.packetBytes));
        stallAt     = -1;
        stallCycles = 0;
        padBytes    = f.padBytes;
    end

    emitted = emitted + 1;
    items(emitted) = struct('bytes', f.packetBytes, ...
        'gapBefore', p.IFG_BYTES, 'er', f.er);

    stim(emitted) = struct('index', k, 'payload', payload, 'da', da, ...
        'sa', sa, 'etherType', etherType, 'readyGap', readyGaps(k), ...
        'stallAt', stallAt, 'stallCycles', stallCycles);

    records(emitted) = struct('index', k, 'payloadLen', len, ...
        'padBytes', padBytes, 'expectRejected', false, ...
        'expectAborted', aborts, 'stallAt', stallAt, ...
        'gapBefore', p.IFG_BYTES, 'readyGap', readyGaps(k));
end

if opts.IncludeOversize
    % R6: presented to the MAC, refused, counted -- and crucially, nothing
    % appears on the wire for it. The expected cycle stream below therefore
    % does NOT contain a frame here, which is exactly what makes this a real
    % test: a MAC that quietly truncates to 1500 and transmits would produce
    % extra cycles and fail.
    k = nFrames + 1;
    stim(end+1) = struct('index', k, ...
        'payload', uint8(mod(0:p.MAX_PAYLOAD_BYTES, 251)), ...
        'da', da, 'sa', sa, 'etherType', etherType, 'readyGap', 0, ...
        'stallAt', -1, 'stallCycles', 0);
    records(end+1) = struct('index', k, ...
        'payloadLen', p.MAX_PAYLOAD_BYTES + 1, 'padBytes', 0, ...
        'expectRejected', true, 'expectAborted', false, 'stallAt', -1, ...
        'gapBefore', p.IFG_BYTES, 'readyGap', 0);
end

[bytes, dv, er] = gem.buildStream(items);
cycles = gem.rgmiiEncode(bytes, dv, er);

s = struct( ...
    'name',      name, ...
    'direction', 'tx', ...
    'seed',      double(opts.Seed), ...
    'options',   opts, ...
    'records',   records, ...
    'stim',      stim, ...
    'cycles',    cycles, ...
    'counters',  struct('tx_ok', emitted - underruns, ...
                        'tx_rejected', double(opts.IncludeOversize), ...
                        'tx_underrun', underruns));
end

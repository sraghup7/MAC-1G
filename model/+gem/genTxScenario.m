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
%
%   TX is the easy direction and it is worth being clear about why: the MAC
%   owns the timing. It emits the full 7-octet preamble and the full 12-octet
%   inter-frame gap every time (R5), so unlike the RX path there is no
%   shrunken-gap case to survive -- gap shrinkage is something that happens to
%   a receiver, not something a compliant transmitter does to itself.
%
%   BACKPRESSURE, and an open item. The tready profiles here stall only
%   *between* frames, never inside one. Mid-frame stalling is deliberately not
%   generated, because the spec does not say what should happen: at one byte
%   per cycle with no slack (B.3) a MAC that has already started a frame
%   cannot pause, so it must either buffer whole frames before starting
%   (latency and a BRAM the design does not budget for) or underrun and abort
%   the frame with TX_ER. R7 only promises line rate "when user logic supplies
%   data every cycle" and never says what happens otherwise. Rather than
%   invent an answer here and bake it into the vectors, this is recorded as an
%   open item in verification_plan.md, to be decided before the TX datapath is
%   written in Stage 4.
%
%   See also GEM.GENSCENARIO, GEM.WRITEVECTORS, GEM.BUILDFRAME.

arguments
    name (1,:) char
    opts.Seed        (1,1) {mustBeNumeric} = 20260814
    opts.NumFrames   (1,1) {mustBeNumeric, mustBePositive} = 32
    opts.Lengths           {mustBeNumeric} = []
    opts.ReadyMode   (1,:) char {mustBeMember(opts.ReadyMode, ...
                        {'always','gaps','random'})} = 'always'
    opts.MaxPayload        {mustBeNumeric} = []
    opts.IncludeOversize (1,1) logical = false
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
                 'expectRejected', {}, 'gapBefore', {}, 'readyGap', {});
items   = struct('bytes', {}, 'gapBefore', {});
stim    = struct('index', {}, 'payload', {}, 'da', {}, 'sa', {}, ...
                 'etherType', {}, 'readyGap', {});

% Stalls sit between frames only -- see the note above.
switch opts.ReadyMode
    case 'always', readyGaps = zeros(1, nFrames);
    case 'gaps',   readyGaps = repmat(8, 1, nFrames);
    case 'random', readyGaps = randi([0 32], 1, nFrames);
end

emitted = 0;
for k = 1:nFrames
    len = lengthPick(k);
    payload = uint8(mod((0:len-1) + k, 251));
    f = gem.buildFrame(payload, da, sa, etherType);

    emitted = emitted + 1;
    items(emitted) = struct('bytes', f.packetBytes, 'gapBefore', p.IFG_BYTES);

    stim(emitted) = struct('index', k, 'payload', payload, 'da', da, ...
        'sa', sa, 'etherType', etherType, 'readyGap', readyGaps(k));

    records(emitted) = struct('index', k, 'payloadLen', len, ...
        'padBytes', f.padBytes, 'expectRejected', false, ...
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
        'da', da, 'sa', sa, 'etherType', etherType, 'readyGap', 0);
    records(end+1) = struct('index', k, ...
        'payloadLen', p.MAX_PAYLOAD_BYTES + 1, 'padBytes', 0, ...
        'expectRejected', true, 'gapBefore', p.IFG_BYTES, 'readyGap', 0);
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
    'counters',  struct('tx_ok', emitted, ...
                        'tx_rejected', double(opts.IncludeOversize)));
end

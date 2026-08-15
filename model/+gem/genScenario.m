function s = genScenario(name, opts)
%GENSCENARIO Build one reproducible, self-describing stimulus scenario.
%   S = GEM.GENSCENARIO(NAME) returns a struct carrying everything a testbench
%   needs for one run: the RGMII cycle stream to drive, the AXI-Stream beats
%   and counter values to expect, and a record per frame describing what was
%   done to it.
%
%   Options (all name-value):
%       Seed          RNG seed. Default: derived from NAME by
%                     GEM.SEEDFOR, so every scenario gets its own.
%       NumFrames     how many frames to emit. Default 32.
%       Lengths       payload lengths to cycle through. Default: the B.4
%                     boundary set plus a spread of ordinary sizes.
%       Corruptions   cellstr of GEM.CORRUPT kinds to cycle through.
%                     Default {'none'} -- corruption is opt-in, because a
%                     scenario made entirely of broken frames never checks
%                     that good ones still work.
%       GapMode       'nominal' (12) | 'min' (8) | 'random' (8..40).
%       PreambleMode  'full' (7) | 'none' (0) | 'random' (a seeded order that
%                     covers every length 0..7 before repeating).
%       Offsets       explicit corruption offsets, cycled over the frames.
%                     Default [] draws them from the seeded stream. Set this
%                     when a corruption has to land on an exact boundary.
%       GarbageRate   0..1, fraction of gaps carrying nonzero octets (R11).
%       MaxPayload    cap on payload length, default GEM_SIM_SCALE. Lets a
%                     smoke run finish in seconds and the full run use 1500.
%
%   ---------------------------------------------------------------------
%   Two properties are designed in rather than hoped for.
%
%   REPRODUCIBILITY. Exactly one RNG is seeded, here, and every random choice
%   in the scenario is drawn from it before anything is built. A failure is
%   re-runnable from S.seed and S.name alone -- no hidden state, no dependence
%   on call order elsewhere.
%
%   SELF-DESCRIPTION. S.records carries, per frame, what its payload length
%   was, which corruption was applied, at which octet, and what class it is
%   expected to land in. A testbench failure quotes that record, so it reads
%   "frame 812: badfcs at packet octet 37, expected badfcs, got ok" rather
%   than "mismatch at cycle 41203". The flow doc's point about failure
%   messages being actionable is a property of the generator, not of the
%   testbench that prints them.
%
%   ---------------------------------------------------------------------
%   The generator also checks itself. After composing the stream it runs the
%   golden RX path over it and compares the result against its own stated
%   intent. The two are derived completely differently -- one from what was
%   done to each frame, the other from reading the wire -- so agreement is
%   real evidence, and disagreement means the generator is broken and would
%   otherwise have handed the testbench wrong expectations. That check is
%   skipped only for 'badsfd', whose outcome is legitimately unpredictable
%   (see GEM.CORRUPT).
%
%   See also GEM.CORRUPT, GEM.SCENARIOS, GEM.WRITEVECTORS, GEM.EXPECTEDBEATS.

arguments
    name (1,:) char
    opts.Seed               {mustBeNumeric} = []
    opts.NumFrames    (1,1) {mustBeNumeric, mustBePositive} = 32
    opts.Lengths            {mustBeNumeric} = []
    opts.Corruptions        cell = {'none'}
    opts.GapMode      (1,:) char {mustBeMember(opts.GapMode, ...
                            {'nominal','min','random'})} = 'nominal'
    opts.Offsets            {mustBeNumeric} = []
    opts.PreambleMode (1,:) char {mustBeMember(opts.PreambleMode, ...
                            {'full','none','random'})} = 'full'
    opts.GarbageRate  (1,1) {mustBeNumeric} = 0
    opts.MaxPayload         {mustBeNumeric} = []
end

p = gem.params();

maxPayload = opts.MaxPayload;
if isempty(maxPayload)
    maxPayload = p.SIM_SCALE;
end

lengths = opts.Lengths;
if isempty(lengths)
    % B.4's boundary set, plus ordinary sizes so the scenario is not made
    % entirely of edge cases.
    lengths = [1 45 46 47 63 64 65 100 512 1000 1499 1500];
end
lengths = min(double(lengths), maxPayload);

if isempty(opts.Seed)
    opts.Seed = gem.seedFor(name);
end
rng(opts.Seed, 'twister');

nFrames = double(opts.NumFrames);

% --- draw every random choice up front, from the one seeded stream ---------
lengthPick   = lengths(1 + mod(0:nFrames-1, numel(lengths)));
corruptPick  = opts.Corruptions(1 + mod(0:nFrames-1, numel(opts.Corruptions)));
if isempty(opts.Offsets)
    offsets = randi([0 4095], 1, nFrames);
else
    % Explicit offsets, for scenarios that must land a corruption on an exact
    % boundary rather than wherever the stream happens to put it.
    offsets = double(opts.Offsets(1 + mod(0:nFrames-1, numel(opts.Offsets))));
end
garbageRoll  = rand(1, nFrames);
switch opts.PreambleMode
    case 'full',   preambles = repmat(p.PREAMBLE_BYTES, 1, nFrames);
    case 'none',   preambles = zeros(1, nFrames);
    case 'random'
        % Every preamble length 0..7 appears before any repeats, in a seeded
        % order. A plain randi draw does not guarantee that, and did not
        % deliver it: rx_trimmed_preamble claims to sweep 0..7 and its 16
        % frames actually used {0,1,2,3,5,6}, missing 4 and -- more awkwardly
        % -- 7, the standard full-length preamble, in the one scenario whose
        % entire purpose is preamble length. Coverage that depends on a lucky
        % draw is not coverage; it is a coin that has been landing right.
        allLengths = 0:p.PREAMBLE_BYTES;
        reps = ceil(nFrames / numel(allLengths));
        seq  = zeros(1, reps * numel(allLengths));
        for r = 1:reps
            span = (r-1)*numel(allLengths) + (1:numel(allLengths));
            seq(span) = allLengths(randperm(numel(allLengths)));
        end
        preambles = seq(1:nFrames);
end
switch opts.GapMode
    case 'nominal', gaps = repmat(p.IFG_BYTES, 1, nFrames);
    case 'min',     gaps = repmat(p.IFG_RX_MIN_BYTES, 1, nFrames);
    case 'random',  gaps = randi([p.IFG_RX_MIN_BYTES 40], 1, nFrames);
end

da = uint8([hex2dec('00') hex2dec('0A') hex2dec('35') 1 2 3]);
sa = uint8([hex2dec('DE') hex2dec('AD') hex2dec('BE') hex2dec('EF') 0 1]);
etherType = hex2dec('0800');

% --- build the items ------------------------------------------------------
items   = struct('bytes', {}, 'er', {}, 'dv', {}, 'gapBefore', {}, 'gapData', {});
records = struct('index', {}, 'payloadLen', {}, 'corruption', {}, ...
                 'offset', {}, 'expectedClass', {}, 'preambleBytes', {}, ...
                 'gapBefore', {}, 'garbageInGap', {});

for k = 1:nFrames
    len = lengthPick(k);
    payload = uint8(mod((0:len-1) + k, 251));

    frame = gem.buildFrame(payload, da, sa, etherType, ...
        PreambleBytes=preambles(k));

    item = gem.corrupt(frame, corruptPick{k}, offsets(k));
    item.gapBefore = gaps(k);

    garbage = garbageRoll(k) < opts.GarbageRate;
    if garbage
        % R11: octets on the bus with DV low. Deliberately seeded with 0xD5 so
        % a hunter that scans while DV is deasserted is caught immediately.
        item.gapData = uint8(mod((1:gaps(k)) * 37 + k, 256));
        item.gapData(min(3, gaps(k))) = uint8(p.SFD_OCTET);
    end

    items(k) = struct('bytes', item.bytes, 'er', item.er, 'dv', item.dv, ...
        'gapBefore', item.gapBefore, 'gapData', item.gapData);

    records(k) = struct('index', k, 'payloadLen', len, ...
        'corruption', item.kind, 'offset', item.offset, ...
        'expectedClass', item.expectedClass, ...
        'preambleBytes', preambles(k), 'gapBefore', gaps(k), ...
        'garbageInGap', garbage);
end

% --- compose the wire, then read it back with the golden RX ---------------
[bytes, dv, er] = gem.buildStream(items);
cycles = gem.rgmiiEncode(bytes, dv, er);

found = gem.deframe(bytes, dv, er);
[beats, counters] = gem.expectedBeats(found);

s = struct( ...
    'name',       name, ...
    'seed',       double(opts.Seed), ...
    'options',    opts, ...
    'records',    records, ...
    'cycles',     cycles, ...
    'stream',     struct('bytes', bytes, 'dv', dv, 'er', er), ...
    'frames',     found, ...
    'beats',      beats, ...
    'counters',   counters);

s.selfCheck = crossCheck(records, found, name);
end


function report = crossCheck(records, found, name)
%CROSSCHECK Compare the generator's intent against the golden model's reading.
%
%   The two disagree only if the generator is broken -- in which case every
%   expectation it just wrote out is wrong, and the testbench would spend the
%   afternoon blaming the RTL.

% Alignment is positional and stays that way even when badsfd is present.
% GEM.DEFRAME returns one entry per DV burst -- including bursts in which no
% SFD was ever found (.sfdFound false) -- and every item this generator emits
% is exactly one burst, because gapBefore is never zero and garbage in the gap
% carries DV low. So found(k) corresponds to records(k), always.
%
% The previous version filtered `found` by .sfdFound before comparing, which is
% what actually destroyed the alignment: a badsfd frame that produced no burst
% entry in the filtered list shifted every later frame by one. The response was
% to abandon the cross-check for the whole scenario the moment one badsfd
% appeared -- which switched off the generator's strongest self-check on
% rx_bad_sfd and on random_rx_sweep's 600 frames, the two scenarios doing the
% most work. Worse, `checked` was reported as the predictable-frame count while
% nothing had been checked at all, so the report claimed coverage it did not
% have.
%
% Now: skip precisely the frames whose class is genuinely unpredictable, and
% check every other one.
if numel(found) ~= numel(records)
    error('gem:generatorFrameCount', ...
        ['Scenario "%s": generated %d items but the golden deframer found ' ...
         '%d DV bursts. The generator and the model disagree about the ' ...
         'shape of the wire, before any classification is even attempted.'], ...
        name, numel(records), numel(found));
end

checked = 0;
skipped = 0;

for k = 1:numel(records)
    if isempty(records(k).expectedClass)
        % badsfd: the hunter may legitimately latch onto a later 0xD5 and
        % produce a frame of unpredictable class, or find nothing at all.
        % Both are R8-correct, so there is nothing to assert.
        skipped = skipped + 1;
        continue
    end

    if ~found(k).sfdFound
        error('gem:generatorFrameLost', ...
            ['Scenario "%s", frame %d (payload %d B, %s at octet %d): the ' ...
             'generator emitted a frame the golden deframer never framed. ' ...
             'The generator is wrong, not the design under test.'], ...
            name, k, records(k).payloadLen, records(k).corruption, ...
            records(k).offset);
    end

    actual = gem.parseFrame(found(k).frameBytes, RxErr=found(k).rxErr).class;
    if ~strcmp(actual, records(k).expectedClass)
        error('gem:generatorIntentMismatch', ...
            ['Scenario "%s", frame %d (payload %d B, %s at octet %d): ' ...
             'generator intended class "%s" but the golden model reads ' ...
             '"%s". The generator is wrong, not the design under test.'], ...
            name, k, records(k).payloadLen, records(k).corruption, ...
            records(k).offset, records(k).expectedClass, actual);
    end
    checked = checked + 1;
end

report = struct('checked', checked, 'skipped', skipped, 'ok', true);

if skipped > 0
    report.note = sprintf(['%d frames cross-checked, all agree; %d badsfd ' ...
        'frame(s) skipped as legitimately unpredictable.'], checked, skipped);
else
    report.note = sprintf('%d frames cross-checked, all agree.', checked);
end
end

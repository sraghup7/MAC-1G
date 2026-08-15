function s = genScenario(name, opts)
%GENSCENARIO Build one reproducible, self-describing stimulus scenario.
%   S = GEM.GENSCENARIO(NAME) returns a struct carrying everything a testbench
%   needs for one run: the RGMII cycle stream to drive, the AXI-Stream beats
%   and counter values to expect, and a record per frame describing what was
%   done to it.
%
%   Options (all name-value):
%       Seed          RNG seed. Default 20260814.
%       NumFrames     how many frames to emit. Default 32.
%       Lengths       payload lengths to cycle through. Default: the B.4
%                     boundary set plus a spread of ordinary sizes.
%       Corruptions   cellstr of GEM.CORRUPT kinds to cycle through.
%                     Default {'none'} -- corruption is opt-in, because a
%                     scenario made entirely of broken frames never checks
%                     that good ones still work.
%       GapMode       'nominal' (12) | 'min' (8) | 'random' (8..40).
%       PreambleMode  'full' (7) | 'none' (0) | 'random' (0..7).
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
    opts.Seed         (1,1) {mustBeNumeric} = 20260814
    opts.NumFrames    (1,1) {mustBeNumeric, mustBePositive} = 32
    opts.Lengths            {mustBeNumeric} = []
    opts.Corruptions        cell = {'none'}
    opts.GapMode      (1,:) char {mustBeMember(opts.GapMode, ...
                            {'nominal','min','random'})} = 'nominal'
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

rng(opts.Seed, 'twister');

nFrames = double(opts.NumFrames);

% --- draw every random choice up front, from the one seeded stream ---------
lengthPick   = lengths(1 + mod(0:nFrames-1, numel(lengths)));
corruptPick  = opts.Corruptions(1 + mod(0:nFrames-1, numel(opts.Corruptions)));
offsets      = randi([0 4095], 1, nFrames);
garbageRoll  = rand(1, nFrames);
switch opts.PreambleMode
    case 'full',   preambles = repmat(p.PREAMBLE_BYTES, 1, nFrames);
    case 'none',   preambles = zeros(1, nFrames);
    case 'random', preambles = randi([0 p.PREAMBLE_BYTES], 1, nFrames);
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

predictable = ~cellfun(@isempty, {records.expectedClass});
nPredictable = nnz(predictable);

report = struct('checked', nPredictable, 'skipped', nnz(~predictable), ...
                'ok', true);

if any(~predictable)
    % 'badsfd' can add or remove a frame, so positional alignment is gone.
    % Say so rather than silently checking the wrong pairs.
    report.ok = true;
    report.note = sprintf(['%d frame(s) use badsfd, whose outcome is ' ...
        'legitimately unpredictable; positional cross-check skipped for ' ...
        'this scenario.'], nnz(~predictable));
    return
end

real = found([found.sfdFound]);
if numel(real) ~= numel(records)
    error('gem:generatorFrameCount', ...
        ['Scenario "%s": generated %d frames but the golden deframer found ' ...
         '%d. The generator and the model disagree about the wire.'], ...
        name, numel(records), numel(real));
end

for k = 1:numel(records)
    actual = gem.parseFrame(real(k).frameBytes, RxErr=real(k).rxErr).class;
    if ~strcmp(actual, records(k).expectedClass)
        error('gem:generatorIntentMismatch', ...
            ['Scenario "%s", frame %d (payload %d B, %s at octet %d): ' ...
             'generator intended class "%s" but the golden model reads ' ...
             '"%s". The generator is wrong, not the design under test.'], ...
            name, k, records(k).payloadLen, records(k).corruption, ...
            records(k).offset, records(k).expectedClass, actual);
    end
end

report.note = sprintf('%d frames cross-checked, all agree.', nPredictable);
end

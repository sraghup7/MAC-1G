function outDir = writeVectors(s, outDir)
%WRITEVECTORS Emit a scenario as the files the SystemVerilog testbench reads.
%   OUTDIR = GEM.WRITEVECTORS(S) writes scenario S into
%   model/vectors/<S.name>/ and returns the path. GEM.WRITEVECTORS(S, OUTDIR)
%   writes somewhere else.
%
%   Files, for an RX scenario:
%
%     rx_rgmii.hex          one 12-bit word per rx_clk cycle, 3 hex chars per
%                           line, ready for $readmemh. Bit layout is documented
%                           in GEM.RGMIIENCODE.
%     rx_expected.txt       one line per AXI-S beat: data(hex) last user frame
%     counters_expected.txt name value, one per line (R17)
%     manifest.json         seed, options, and the per-frame record
%
%   and for a TX scenario:
%
%     tx_stim.txt           one line per frame: index readyGap etherType
%                           da(hex) sa(hex) payload(hex)
%     tx_expected.hex       the RGMII cycles the MAC must produce
%     counters_expected.txt
%     manifest.json
%
%   Everything is plain text on purpose. A vector format you cannot read with
%   `head` is one you cannot debug at 2am, and the whole value of these files
%   is that when a testbench says "beat 4021 differs" you can go look at beat
%   4021.
%
%   manifest.json is the reproducibility contract: it carries the seed and
%   every generator option, so any scenario can be regenerated bit-identically
%   from it alone. model/tests/tGenerator.m asserts that it can.
%
%   See also GEM.GENSCENARIO, GEM.GENTXSCENARIO, GEM.SCENARIOS.

arguments
    s      struct
    outDir (1,:) char = ''
end

if isempty(outDir)
    outDir = fullfile(gem.repoRoot(), 'model', 'vectors', s.name);
end
if ~isfolder(outDir)
    mkdir(outDir);
end

direction = 'rx';
if isfield(s, 'direction')
    direction = s.direction;
end

switch direction
    case 'rx'
        writeHex(fullfile(outDir, 'rx_rgmii.hex'), s.cycles);
        writeBeats(fullfile(outDir, 'rx_expected.txt'), s.beats);
    case 'tx'
        writeHex(fullfile(outDir, 'tx_expected.hex'), s.cycles);
        writeTxStim(fullfile(outDir, 'tx_stim.txt'), s.stim);
    otherwise
        error('gem:unknownDirection', 'Unknown scenario direction "%s".', direction);
end

writeCounters(fullfile(outDir, 'counters_expected.txt'), s.counters);
writeManifest(fullfile(outDir, 'manifest.json'), s, direction);
end


function writeHex(path, cycles)
% Three hex characters per line: the RGMII word is 10 significant bits.
fid = openOrFail(path);
c = onCleanup(@() fclose(fid));
fprintf(fid, '%03X\n', uint16(cycles));
end


function writeBeats(path, beats)
fid = openOrFail(path);
c = onCleanup(@() fclose(fid));
fprintf(fid, '# data last user frame sfdCycle\n');
for k = 1:numel(beats.data)
    fprintf(fid, '%02X %d %d %d %d\n', beats.data(k), beats.last(k), ...
        beats.user(k), beats.frameId(k), beats.sfdCycle(k));
end
end


function writeTxStim(path, stim)
fid = openOrFail(path);
c = onCleanup(@() fclose(fid));
fprintf(fid, '# index readyGap etherType da sa payload\n');
for k = 1:numel(stim)
    fprintf(fid, '%d %d %04X %s %s %s\n', ...
        stim(k).index, stim(k).readyGap, stim(k).etherType, ...
        hexString(stim(k).da), hexString(stim(k).sa), ...
        hexString(stim(k).payload));
end
end


function writeCounters(path, counters)
fid = openOrFail(path);
c = onCleanup(@() fclose(fid));
names = fieldnames(counters);
for k = 1:numel(names)
    fprintf(fid, '%s %d\n', names{k}, counters.(names{k}));
end
end


function writeManifest(path, s, direction)
manifest = struct( ...
    'name',       s.name, ...
    'direction',  direction, ...
    'seed',       s.seed, ...
    'generated',  char(datetime('now', 'Format', 'uuuu-MM-dd''T''HH:mm:ss')), ...
    'options',    s.options, ...
    'counters',   s.counters, ...
    'records',    s.records);

if isfield(s, 'selfCheck')
    manifest.selfCheck = s.selfCheck;
end

fid = openOrFail(path);
c = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', jsonencode(manifest, 'PrettyPrint', true));
end


function str = hexString(bytes)
if isempty(bytes)
    str = '-';
else
    str = reshape(dec2hex(uint8(bytes), 2).', 1, []);
end
end


function fid = openOrFail(path)
fid = fopen(path, 'w');
if fid < 0
    error('gem:cannotWrite', 'Could not open %s for writing.', path);
end
end

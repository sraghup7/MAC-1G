function crcs = crc32Reference(vectors)
%CRC32REFERENCE CRC-32 of each vector, computed by Python's zlib.
%   CRCS = GEM.CRC32REFERENCE(VECTORS) takes a cell array of byte vectors and
%   returns a uint32 row vector of their CRC-32 values, computed by an
%   implementation this project did not write. Returns [] if Python is not
%   available, so the cross-check degrades to "skipped" rather than "failed".
%
%   This exists to answer the question a self-consistent model cannot: is the
%   algorithm right, or merely consistently wrong? zlib.crc32 is the same
%   CRC-32/ISO-HDLC parameter set the FCS uses, written by other people, and
%   shipped with every Python install -- so it costs nothing and is genuinely
%   independent.
%
%   The exchange goes through temp files rather than MATLAB's Python bridge so
%   it works on a machine where `pyenv` was never configured.
%
%   See also GEM.CRC32.

crcs = uint32([]);

tmpDir  = tempname();
mkdir(tmpDir);
cleanup = onCleanup(@() rmdir(tmpDir, 's'));

dataFile = fullfile(tmpDir, 'vectors.bin');
outFile  = fullfile(tmpDir, 'crcs.txt');
pyFile   = fullfile(tmpDir, 'ref.py');

% Length-prefixed concatenation: a 4-byte little-endian length, then that many
% octets, repeated. Avoids any text encoding question entirely.
fid = fopen(dataFile, 'wb');
if fid < 0
    return
end
for k = 1:numel(vectors)
    v = uint8(vectors{k}(:).');
    fwrite(fid, uint32(numel(v)), 'uint32');
    if ~isempty(v)
        fwrite(fid, v, 'uint8');
    end
end
fclose(fid);

script = [ ...
    "import struct, zlib, sys"
    "src, dst = sys.argv[1], sys.argv[2]"
    "out = []"
    "with open(src, 'rb') as f:"
    "    while True:"
    "        hdr = f.read(4)"
    "        if len(hdr) < 4:"
    "            break"
    "        n = struct.unpack('<I', hdr)[0]"
    "        out.append('%08X' % zlib.crc32(f.read(n)))"
    "with open(dst, 'w') as f:"
    "    f.write('\n'.join(out))"
    ];
writelines(script, pyFile);

for interpreter = ["python", "python3", "py"]
    cmd = sprintf('%s "%s" "%s" "%s"', interpreter, pyFile, dataFile, outFile);
    [status, ~] = system(cmd);
    if status == 0 && isfile(outFile)
        text = strtrim(fileread(outFile));
        if isempty(text)
            return
        end
        lines = splitlines(string(text));
        crcs = uint32(hex2dec(lines))';
        return
    end
end
end

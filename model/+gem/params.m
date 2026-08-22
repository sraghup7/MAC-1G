function p = params(force)
%PARAMS Design constants, read from the RTL's own parameter header.
%   P = GEM.PARAMS() returns a struct of every GEM_* constant defined in
%   rtl/gem_mac_params.vh, with the "GEM_" prefix stripped:
%
%       p.MIN_FRAME_BYTES, p.IFG_BYTES, p.CRC32_POLY, ...
%
%   P = GEM.PARAMS(true) bypasses the cache and re-reads the file.
%
%   The model deliberately does *not* keep its own copy of these numbers. A
%   golden model whose constants are typed in a second time is a model that
%   can drift from the RTL silently -- and "the model and the design disagree
%   about MIN_FRAME_BYTES" is a bug that looks exactly like a real RTL failure
%   while costing a day to find. Parsing the header instead makes that class
%   of bug impossible rather than merely unlikely. model/tests/tParams.m
%   checks the parse itself against known values.
%
%   See also GEM.CRC32, GEM.BUILDFRAME.

persistent cached cachedStamp

headerFile = fullfile(gem.repoRoot(), 'rtl', 'gem_mac_params.vh');
info = dir(headerFile);
if isempty(info)
    error('gem:paramsNotFound', ...
        'Parameter header not found at %s.', headerFile);
end

% The cache is keyed on the header's modification time and size, not merely on
% "have we read it once". Caching unconditionally would defeat the entire point
% of this function: edit gem_mac_params.vh in an interactive session and every
% subsequent call would keep returning the OLD constants, so the model would
% silently drift from the RTL it exists to stay in step with -- and the symptom
% would be a testbench mismatch that looks exactly like an RTL bug.
%
% A dir() stat per call is microseconds; the fileread plus two regex passes it
% avoids is not. `matlab -batch` gets a fresh process each time so the make
% targets were never exposed to this, but the interactive workflow -- which is
% precisely how someone edits parameters -- was.
stamp = [info.datenum, info.bytes];

if nargin >= 1 && force
    cached = [];
end
if ~isempty(cached) && isequal(stamp, cachedStamp)
    p = cached;
    return
end

text = fileread(headerFile);

% Strip comments so prose cannot be picked up as constants. Block comments
% go first: a /* ... */ containing // or a `define must contribute nothing,
% and stripping line comments first could expose a `define inside a block
% comment to the match below.
text = regexprep(text, '/\*[\s\S]*?\*/', '');
text = regexprep(text, '//[^\n]*', '');

% Match:  `define GEM_NAME  VALUE
%
% The separators are [^\S\r\n] (horizontal whitespace only), not \s, so the
% match cannot run across a line break. Plain \s+ would let the valueless
% include guard -- `define GEM_MAC_PARAMS_VH -- swallow the next line's
% `define as its value.
tokens = regexp(text, '`define[^\S\r\n]+GEM_(\w+)[^\S\r\n]+(\S+)', 'tokens');
if isempty(tokens)
    error('gem:paramsEmpty', ...
        'No `define GEM_* entries parsed from %s.', headerFile);
end

p = struct();
for k = 1:numel(tokens)
    name = tokens{k}{1};
    % The Verilog preprocessor resolves duplicates last-one-wins; here a
    % duplicate is far more likely to be a merge accident or an #ifdef-style
    % pairing whose both branches this parser cannot evaluate. Silently
    % taking either branch is exactly the silent drift this parser exists to
    % make impossible, so refuse loudly instead.
    if isfield(p, name)
        error('gem:paramsDuplicate', ...
            ['GEM_%s is defined more than once in %s. The RTL preprocessor ', ...
             'would quietly take the last one; this parser will not guess.'], ...
            name, headerFile);
    end
    p.(name) = tokens{k}{2};   % keep raw for now; resolved below
end

% Resolve in two passes: literals first, then the entries whose value is a
% reference to another macro (GEM_SIM_SCALE defaults to GEM_MAX_PAYLOAD_BYTES).
names = fieldnames(p);
for k = 1:numel(names)
    raw = p.(names{k});
    if ~startsWith(raw, '`')
        p.(names{k}) = parseVerilogLiteral(raw, names{k});
    end
end
for k = 1:numel(names)
    raw = p.(names{k});
    if ischar(raw) && startsWith(raw, '`')
        ref = regexprep(raw, '^`GEM_', '');
        if ~isfield(p, ref) || ischar(p.(ref))
            error('gem:paramsUnresolved', ...
                'GEM_%s references %s, which did not resolve.', names{k}, raw);
        end
        p.(names{k}) = p.(ref);
    end
end

cached      = p;
cachedStamp = stamp;
end


function value = parseVerilogLiteral(raw, name)
%PARSEVERILOGLITERAL Convert 32'h04C11DB7 / 8'h55 / 1518 to a number.
raw = strtrim(raw);

sized = regexp(raw, "^(\d*)'([hdb])([0-9a-fA-F_]+)$", 'tokens', 'once');
if ~isempty(sized)
    digits = strrep(sized{3}, '_', '');
    switch lower(sized{2})
        case 'h', value = uint64(hex2dec(digits));
        case 'd', value = uint64(str2double(digits));
        case 'b', value = uint64(bin2dec(digits));
    end
    width = str2double(sized{1});
    if isnan(width)
        % Unsized literal ('h55): nothing to enforce the digits against; the
        % uint32-or-wider choice below still applies.
        if double(value) < 4294967296
            value = uint32(value);
        end
    else
        % ENFORCE THE DECLARED WIDTH. The RTL truncates oversized digits to
        % the declared width without complaint -- 8'h1D5 is 8'hD5 to every
        % Verilog tool -- and a model that kept all three nibbles would
        % disagree with the hardware silently, which is the one failure this
        % parser exists to make impossible. Refuse instead of truncating.
        if width < 1 || width > 64 || double(value) >= 2^width
            error('gem:paramsWidth', ...
                ['GEM_%s declares width %d but its digits carry a value that ', ...
                 'does not fit (%s). The RTL would truncate silently; fix the ', ...
                 'header rather than letting the model and the design diverge.'], ...
                name, width, raw);
        end
        % Widths up to 32 bits land in uint32, which is what the CRC math
        % wants; anything wider stays uint64 rather than silently truncating.
        if width <= 32
            value = uint32(value);
        end
    end
    return
end

plain = str2double(raw);
if isnan(plain)
    error('gem:paramsBadLiteral', ...
        'Could not parse value "%s" of GEM_%s.', raw, name);
end
value = plain;
end

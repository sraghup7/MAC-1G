function genVectors(varargin)
%GENVECTORS Regenerate every scenario's vector files.
%   GENVECTORS() builds all scenarios into model/vectors/.
%   GENVECTORS('Set', 'frozen') builds only the committed directed set.
%   GENVECTORS('Exit', true) exits with a nonzero status on any failure,
%   which is how `make vectors` gates.
%
%   Called by `make vectors`. Every scenario's own generator cross-check runs
%   as part of building it (see GEM.GENSCENARIO), so this target failing means
%   the generator disagrees with the golden model -- not that the design is
%   broken. That distinction is the whole reason the check exists.

%   GENVECTORS('Dir', PATH) writes somewhere other than model/vectors/, which
%   is how scripts/check_vectors.py regenerates into a temporary directory and
%   diffs against what is committed.

opts = struct('Set', 'all', 'Exit', false, 'Dir', '');
for k = 1:2:numel(varargin)
    opts.(varargin{k}) = varargin{k+1};
end

here = fileparts(mfilename('fullpath'));
addpath(here);

list = gem.scenarios(opts.Set);
fprintf('Generating %d scenario(s)...\n\n', numel(list));

failures = 0;
for k = 1:numel(list)
    try
        s = list(k).build();
        if isempty(opts.Dir)
            outDir = gem.writeVectors(s);
        else
            outDir = gem.writeVectors(s, fullfile(opts.Dir, s.name));
        end

        switch list(k).direction
            case 'rx'
                detail = sprintf('%5d cycles, %5d beats, counters [ok %d bad %d runt %d over %d rxer %d]', ...
                    numel(s.cycles), numel(s.beats.data), ...
                    s.counters.rx_ok, s.counters.rx_badfcs, s.counters.rx_runt, ...
                    s.counters.rx_oversize, s.counters.rx_rxer);
            case 'tx'
                detail = sprintf('%5d cycles, %5d frames, %d rejected', ...
                    numel(s.cycles), s.counters.tx_ok, s.counters.tx_rejected);
        end

        fprintf('  %-22s %-3s %s\n', list(k).name, list(k).direction, detail);
        fprintf('  %-22s -> %s\n', '', outDir);
    catch err
        failures = failures + 1;
        fprintf(2, '  %-22s FAILED: %s\n', list(k).name, err.message);
    end
end

fprintf('\n%d of %d scenario(s) generated.\n', numel(list) - failures, numel(list));

if opts.Exit
    exit(double(failures > 0));
end
if failures > 0
    error('gem:vectorGenerationFailed', '%d scenario(s) failed.', failures);
end
end

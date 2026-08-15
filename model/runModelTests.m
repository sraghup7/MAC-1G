function results = runModelTests(varargin)
%RUNMODELTESTS Run the golden model's own test suite.
%   RESULTS = RUNMODELTESTS() runs every test in model/tests and returns the
%   matlab.unittest result array. Called by `make model`.
%
%   RUNMODELTESTS('Exit', true) additionally exits MATLAB with a nonzero
%   status if anything failed -- which is how the Makefile target and any CI
%   job gate on it. A build script that reads exit codes is the point;
%   "look at the output and see if it seems fine" is not a gate.
%
%   This suite validates the model itself, not the RTL. It has to be green
%   before any simulation result means anything, because a testbench compares
%   the design against this model and nothing compares the model against
%   anything else.

opts = struct('Exit', false);
for k = 1:2:numel(varargin)
    opts.(varargin{k}) = varargin{k+1};
end

here = fileparts(mfilename('fullpath'));
addpath(here);                       % puts +gem on the path

suite   = matlab.unittest.TestSuite.fromFolder(fullfile(here, 'tests'));
runner  = matlab.unittest.TestRunner.withTextOutput( ...
    'OutputDetail', matlab.unittest.Verbosity.Concise);
results = runner.run(suite);

summary = table(results);
disp(summary);

failed     = nnz([results.Failed]);
incomplete = nnz([results.Incomplete]);

% Incomplete counts as failure for the gate. A test that skipped an assumption
% -- zlib unavailable, say -- has NOT verified what it claims to verify, and
% tCrc32/agreesWithZlib is one of only two independent checks on the CRC. A
% gate that reads green because a check quietly did not run is the failure mode
% this whole stage exists to prevent.
failed = failed + incomplete;
fprintf('\n%d passed, %d failed, %d incomplete, %.2f s total\n', ...
    nnz([results.Passed]), failed, nnz([results.Incomplete]), ...
    sum([results.Duration]));

if opts.Exit
    if failed > 0
        fprintf(2, 'MODEL TESTS FAILED -- the golden model is not trustworthy.\n');
        exit(1);
    end
    exit(0);
end
end

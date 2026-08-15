function root = repoRoot()
%REPOROOT Absolute path to the MAC1G repository root.
%   ROOT = GEM.REPOROOT() locates the repository from this file's own
%   position (model/+gem/repoRoot.m -> up three levels), so the model works
%   regardless of the caller's current directory. Nothing in the model may
%   depend on pwd -- a regression that only passes when launched from the
%   right folder is not a regression.

here = fileparts(mfilename('fullpath'));      % .../model/+gem
root = fileparts(fileparts(here));            % .../
end

function seed = seedFor(name)
%SEEDFOR Deterministic per-scenario RNG seed, derived from the scenario name.
%   SEED = GEM.SEEDFOR(NAME) returns the seed a scenario uses when its build
%   call does not pass one explicitly.
%
%   Every scenario used to share one hard-coded default, and that quietly
%   removed most of the value of having several of them. Two scenarios with the
%   same NumFrames, length set and gap mode -- rx_bad_fcs and rx_runt, say --
%   draw in the same order from the same seeded stream, so their corruption
%   offsets came out *identical*. They differed only in which corruption was
%   applied, at exactly the same places. A bug that survives one offset pattern
%   survived it in every scenario at once.
%
%   Worse for the sweeps: random_rx_sweep started from the same RNG state as
%   the directed tests, so the "random" exploration retraced the trajectory the
%   directed set had already walked. That is the one thing a random sweep is
%   supposed not to do.
%
%   Derived from the NAME rather than from a catalogue index on purpose. An
%   index would mean that inserting or reordering a scenario shifted every
%   later scenario's seed, churning every committed vector file for a change
%   that had nothing to do with them. A name-derived seed moves only when the
%   scenario it belongs to is renamed.
%
%   Reproducibility is untouched: the value is a pure function of the name, it
%   is recorded in each manifest, and gem.genScenario still seeds exactly one
%   RNG from it.
%
%   See also GEM.GENSCENARIO, GEM.GENTXSCENARIO, GEM.SCENARIOS.

arguments
    name (1,:) char
end

% Plain polynomial rolling hash. Nothing here needs cryptographic quality --
% only determinism, and enough spread that two scenario names do not collide.
h = uint64(0);
for k = 1:numel(name)
    h = mod(h * uint64(131) + uint64(double(name(k))), uint64(2147483647));
end

% The original project-wide default stays the base, so the seeds remain
% recognisable as belonging to this project rather than looking arbitrary.
seed = 20260814 + double(mod(h, uint64(1000000)));
end

classdef tGenerator < matlab.unittest.TestCase
    %TGENERATOR Reproducibility and self-description of the stimulus generator.
    %
    %   The generator has two properties the flow doc asks for by name, and
    %   both are testable rather than aspirational:
    %
    %     reproducibility  -- a failure must be re-runnable from its seed
    %                         alone. If regeneration is not bit-identical,
    %                         a failing regression cannot be reproduced and
    %                         the whole apparatus is decorative.
    %     self-description -- every frame carries what was done to it, so a
    %                         failure names the corruption and the offset.
    %
    %   Plus the generator's own cross-check: it states an intent per frame
    %   and then reads the wire back with the golden model. These tests make
    %   sure that check is actually running, not silently skipped.

    methods (Test)

        function sameSeedGivesIdenticalOutput(tc)
            % Bit-identical, not merely equivalent. Anything less and "re-run
            % with seed 20260814" is not a reproduction.
            a = gem.genScenario('repro', NumFrames=20, ...
                Corruptions={'none','badfcs','truncate','rxer'}, ...
                GapMode='random', PreambleMode='random', GarbageRate=0.4);
            b = gem.genScenario('repro', NumFrames=20, ...
                Corruptions={'none','badfcs','truncate','rxer'}, ...
                GapMode='random', PreambleMode='random', GarbageRate=0.4);

            tc.verifyEqual(b.cycles,       a.cycles);
            tc.verifyEqual(b.beats.data,   a.beats.data);
            tc.verifyEqual(b.beats.last,   a.beats.last);
            tc.verifyEqual(b.beats.user,   a.beats.user);
            tc.verifyEqual(b.counters,     a.counters);
            tc.verifyEqual({b.records.corruption}, {a.records.corruption});
            tc.verifyEqual([b.records.offset],     [a.records.offset]);
        end

        function differentSeedGivesDifferentOutput(tc)
            % Guards the opposite failure: a generator that ignores its seed
            % would pass the test above perfectly.
            a = gem.genScenario('s1', Seed=1, NumFrames=20, ...
                Corruptions={'badfcs'}, GapMode='random');
            b = gem.genScenario('s2', Seed=2, NumFrames=20, ...
                Corruptions={'badfcs'}, GapMode='random');

            tc.verifyNotEqual([b.records.offset], [a.records.offset]);
        end

        function everyRecordSelfDescribes(tc)
            s = gem.genScenario('describe', NumFrames=16, ...
                Corruptions={'none','badfcs','truncate','rxer','oversize'});

            tc.verifyNumElements(s.records, 16);
            for k = 1:numel(s.records)
                r = s.records(k);
                tc.verifyEqual(r.index, k);
                tc.verifyNotEmpty(r.corruption);
                tc.verifyGreaterThan(r.payloadLen, 0);
                tc.verifyGreaterThanOrEqual(r.gapBefore, 8);
            end
        end

        function crossCheckActuallyRuns(tc)
            % If this ever reports zero checked frames, the generator has
            % stopped validating itself and nobody would notice.
            s = gem.genScenario('crosscheck', NumFrames=24, ...
                Corruptions={'none','badfcs','truncate','rxer','oversize'});

            tc.verifyTrue(s.selfCheck.ok);
            tc.verifyEqual(s.selfCheck.checked, 24);
            tc.verifyEqual(s.selfCheck.skipped, 0);
        end

        function crossCheckSkipsOnlyBadSfd(tc)
            % badsfd is the one kind whose outcome the generator cannot
            % predict; the skip must be reported, not silent.
            s = gem.genScenario('sfd', NumFrames=8, Corruptions={'badsfd'});
            tc.verifyEqual(s.selfCheck.skipped, 8);
            tc.verifyEqual(s.selfCheck.checked, 0);
            tc.verifyNotEmpty(s.selfCheck.note);
        end

        function badSfdDoesNotDisableTheRestOfTheScenario(tc)
            % The case that was silently broken: a scenario mixing badsfd with
            % predictable corruptions used to abandon the cross-check entirely
            % -- and still report `checked` as the predictable-frame count, so
            % it claimed coverage it did not have. Every non-badsfd frame must
            % actually be checked.
            s = gem.genScenario('mixed', NumFrames=12, ...
                Corruptions={'none','badsfd','badfcs','truncate'});

            tc.verifyEqual(s.selfCheck.checked + s.selfCheck.skipped, 12);
            tc.verifyEqual(s.selfCheck.skipped, 3);   % every 4th frame
            tc.verifyEqual(s.selfCheck.checked, 9);
            tc.verifyTrue(s.selfCheck.ok);
        end

        function crossCheckCoversTheScenariosThatNeedItMost(tc)
            % rx_bad_sfd and random_rx_sweep are the two scenarios that used to
            % run with the cross-check switched off -- the second is the
            % largest in the suite. Both must now check the frames they can.
            for name = ["rx_bad_sfd", "random_rx_sweep"]
                entry = gem.scenarios();
                entry = entry(strcmp({entry.name}, name));
                s = entry.build();

                tc.verifyGreaterThan(s.selfCheck.checked, 0, sprintf( ...
                    '%s cross-checked no frames at all', name));
                tc.verifyGreaterThan(s.selfCheck.skipped, 0, sprintf( ...
                    '%s contains no badsfd, so it is not testing this', name));
            end
        end

        function allCataloguedScenariosBuild(tc)
            % Every row of the catalogue must build and pass its own check.
            % This is what stops a scenario from rotting unnoticed between
            % full regression runs.
            list = gem.scenarios('frozen');
            tc.assertNotEmpty(list);

            for k = 1:numel(list)
                s = list(k).build();
                tc.verifyEqual(s.name, list(k).name);

                if strcmp(list(k).direction, 'rx')
                    tc.verifyTrue(s.selfCheck.ok, ...
                        sprintf('scenario %s failed its self-check', list(k).name));
                    tc.verifyNotEmpty(s.cycles, ...
                        sprintf('scenario %s produced no cycles', list(k).name));
                else
                    tc.verifyNotEmpty(s.stim, ...
                        sprintf('scenario %s produced no stimulus', list(k).name));
                end
            end
        end

        function everyErrorClassIsExercisedSomewhere(tc)
            % B.4's coverage criterion, checked mechanically rather than by
            % reading the catalogue and hoping.
            classes = {'rx_ok','rx_badfcs','rx_runt','rx_oversize','rx_rxer'};
            seen = struct();
            for k = 1:numel(classes)
                seen.(classes{k}) = 0;
            end

            list = gem.scenarios('frozen');
            for k = 1:numel(list)
                if ~strcmp(list(k).direction, 'rx'), continue; end
                s = list(k).build();
                for c = 1:numel(classes)
                    seen.(classes{c}) = seen.(classes{c}) + s.counters.(classes{c});
                end
            end

            for c = 1:numel(classes)
                tc.verifyGreaterThan(seen.(classes{c}), 0, sprintf( ...
                    'No frozen scenario produces any %s frame -- that class is untested.', ...
                    classes{c}));
            end
        end

        function vectorFilesRegenerateByteIdentically(tc)
            % The `make vectors` reproducibility gate, in miniature. Write the
            % same scenario twice into different folders and diff the bytes.
            tmp = tempname();
            mkdir(tmp);
            cleanup = onCleanup(@() rmdir(tmp, 's'));

            dirA = fullfile(tmp, 'a');
            dirB = fullfile(tmp, 'b');

            gem.writeVectors(gem.genScenario('reproFiles', NumFrames=10, ...
                Corruptions={'none','badfcs'}, GapMode='random'), dirA);
            gem.writeVectors(gem.genScenario('reproFiles', NumFrames=10, ...
                Corruptions={'none','badfcs'}, GapMode='random'), dirB);

            % manifest.json carries a timestamp, so it is expected to differ;
            % everything a testbench actually reads must not.
            for f = ["rx_rgmii.hex", "rx_expected.txt", "counters_expected.txt"]
                a = fileread(fullfile(dirA, f));
                b = fileread(fullfile(dirB, f));
                tc.verifyEqual(b, a, sprintf('%s is not reproducible', f));
            end
        end

    end
end

//----------------------------------------------------------------------------
// gem_tb_pkg -- vector file readers, the scoreboard, and the failure reporter.
//
// The reporter is the part that matters. A scoreboard that prints "mismatch at
// cycle 41203" hands you a number and a long afternoon; one that prints
//
//   FAIL rx_recovery_mix beat 4021 (frame 17, payload 64 B, badfcs at octet 37)
//        tdata expected 0x3C, got 0x00
//
// hands you the bug. That difference is designed into the generator (every
// frame carries its own record, see gem.genScenario) and spent here.
//
// Deliberately written without classes: XSim's SystemVerilog class support is
// the patchiest corner of the language, and a verification layer that fails to
// elaborate is worth less than a plainer one that runs.
//----------------------------------------------------------------------------

`ifndef GEM_TB_PKG_SV
`define GEM_TB_PKG_SV

package gem_tb_pkg;

    // Sized for the largest random sweep with room to spare; simulation
    // memory is free compared with the cost of a truncated vector file that
    // silently shortens a test.
    localparam int MAX_CYCLES = 1 << 21;
    localparam int MAX_BEATS  = 1 << 21;
    localparam int MAX_FRAMES = 4096;

    // One AXI-Stream beat as the golden model predicted it.
    typedef struct {
        logic [7:0] data;
        logic       last;
        logic       user;
        int         frameId;
        int         sfdCycle;   // wire cycle that carried this frame's SFD (R21)
    } beat_t;

    // The self-describing record the generator attached to each frame.
    typedef struct {
        int     index;
        int     payloadLen;
        string  corruption;
        int     offset;
        string  expectedClass;
        int     preambleBytes;
        int     gapBefore;
    } record_t;

    //------------------------------------------------------------------
    // Vector file readers
    //------------------------------------------------------------------

    // Reads a .hex of one word per line into WORDS, returns the count.
    // $readmemh cannot be used for the beat/counter files (they carry a
    // comment header), so all three readers are hand-rolled for consistency.
    function automatic int read_cycles(string path, ref logic [11:0] words[]);
        int fd, count, value, code;
        string line;
        begin
            words = new [MAX_CYCLES];
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $fatal(1, "gem_tb: cannot open vector file '%s'", path);
            end
            count = 0;
            while (!$feof(fd)) begin
                code = $fgets(line, fd);
                if (code <= 0) break;
                if (line.substr(0,0) == "#" || line.len() < 2) continue;
                if ($sscanf(line, "%h", value) == 1) begin
                    words[count] = value[11:0];
                    count++;
                end
            end
            $fclose(fd);
            words = new [count] (words);
            return count;
        end
    endfunction

    // Reads "data last user frame sfdCycle" lines into BEATS, returns the count.
    function automatic int read_beats(string path, ref beat_t beats[]);
        int fd, count, code;
        int d, l, u, f, s;
        string line;
        begin
            beats = new [MAX_BEATS];
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $fatal(1, "gem_tb: cannot open expected file '%s'", path);
            end
            count = 0;
            while (!$feof(fd)) begin
                code = $fgets(line, fd);
                if (code <= 0) break;
                if (line.substr(0,0) == "#" || line.len() < 4) continue;
                if ($sscanf(line, "%h %d %d %d %d", d, l, u, f, s) == 5) begin
                    beats[count].data     = d[7:0];
                    beats[count].last     = l[0];
                    beats[count].user     = u[0];
                    beats[count].frameId  = f;
                    beats[count].sfdCycle = s;
                    count++;
                end
            end
            $fclose(fd);
            beats = new [count] (beats);
            return count;
        end
    endfunction

    // Converts a hex string ("DEADBEEF") to bytes. Returns the count, or 0
    // for the "-" placeholder the writer uses for an empty field.
    function automatic int hex_to_bytes(string s, ref logic [7:0] b[]);
        int n, i;
        logic [7:0] value;
        begin
            if (s == "-" || s.len() < 2) begin
                b = new [0];
                return 0;
            end
            n = s.len() / 2;
            b = new [n];
            for (i = 0; i < n; i++) begin
                value = 8'(hex_digit(s.substr(2*i, 2*i)) * 16
                         + hex_digit(s.substr(2*i+1, 2*i+1)));
                b[i] = value;
            end
            return n;
        end
    endfunction

    function automatic int hex_digit(string c);
        case (c)
            "0": return 0;  "1": return 1;  "2": return 2;  "3": return 3;
            "4": return 4;  "5": return 5;  "6": return 6;  "7": return 7;
            "8": return 8;  "9": return 9;
            "a", "A": return 10;  "b", "B": return 11;
            "c", "C": return 12;  "d", "D": return 13;
            "e", "E": return 14;  "f", "F": return 15;
            default: return 0;
        endcase
    endfunction

    // Reads "name value" lines. Returns the value for NAME, or -1 if absent.
    function automatic longint read_counter(string path, string name);
        int fd, code;
        longint value;
        string line, field;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $fatal(1, "gem_tb: cannot open counter file '%s'", path);
            end
            value = -1;
            while (!$feof(fd)) begin
                code = $fgets(line, fd);
                if (code <= 0) break;
                if ($sscanf(line, "%s %d", field, value) == 2) begin
                    if (field == name) begin
                        $fclose(fd);
                        return value;
                    end
                end
            end
            $fclose(fd);
            return -1;
        end
    endfunction

    //------------------------------------------------------------------
    // Which scenario to run
    //------------------------------------------------------------------
    //
    // Read from sim/run.cfg -- two lines, the scenario name then its vector
    // directory -- rather than from a plusarg. Vivado 2024.2's xsim.bat
    // wrapper on Windows mangles `-testplusarg NAME=value`, splitting it at
    // the '=' and failing with "Expected a switch but found r". A file
    // handoff costs one line in the runner, behaves identically on every
    // shell and platform, and leaves a record of what was last run sitting
    // next to the waveform.
    //
    // Falls back to a plusarg, then to a default, so an interactive run on a
    // simulator without that bug still works the usual way.

    function automatic void get_scenario(output string name, output string dir);
        int fd, code;
        string line;
        begin
            name = "";
            dir  = "";

            // Looked for in the working directory first, then one level up,
            // so the same snapshot runs whether it is launched from sim/ or
            // from the repository root. The vector path inside is absolute,
            // which makes the question moot for everything after this point.
            fd = $fopen("run.cfg", "r");
            if (fd == 0) fd = $fopen("sim/run.cfg", "r");
            if (fd != 0) begin
                code = $fgets(line, fd);
                if (code > 0) name = trim_nl(line);
                code = $fgets(line, fd);
                if (code > 0) dir = trim_nl(line);
                $fclose(fd);
            end

            if (name == "") begin
                if (!$value$plusargs("SCENARIO=%s", name)) name = "rx_clean_sweep";
            end
            if (dir == "") begin
                dir = {"model/vectors/", name};
            end
        end
    endfunction

    // Strips trailing CR, LF and spaces.
    //
    // Compares character CODES, not string literals, and that is not fussiness.
    // "\r" is not a SystemVerilog escape sequence -- the LRM defines \n, \t,
    // \\, \", \v, \f, \a and \ddd, and nothing for carriage return. XSim
    // resolves the unknown escape to the bare character 'r', so a literal
    // comparison against "\r" silently becomes a comparison against "r" and
    // eats the last character of any name ending in one. That turned scenario
    // "rx_rxer" into "rx_rxe" and sent the testbench looking for a directory
    // that does not exist -- a failure that would have looked like a missing
    // vector file rather than a string bug, and only for some scenarios.
    function automatic string trim_nl(string s);
        int last;
        byte c;
        begin
            last = s.len() - 1;
            while (last >= 0) begin
                c = s.getc(last);
                if (c == 8'h0D || c == 8'h0A || c == 8'h20 || c == 8'h09) begin
                    last--;
                end else begin
                    break;
                end
            end
            if (last < 0) return "";
            return s.substr(0, last);
        end
    endfunction

    //------------------------------------------------------------------
    // Reporting
    //------------------------------------------------------------------
    //
    // Every failure goes through report_fail so the format is uniform and the
    // count is honest. A testbench that prints its own $error somewhere else
    // will not be counted, and "0 failures" will be a lie -- which is why
    // check_done() reports the tally rather than each test deciding for
    // itself whether it passed.

    int unsigned fail_count = 0;
    int unsigned check_count = 0;
    string       scenario_name = "?";

    function automatic void begin_scenario(string name);
        scenario_name = name;
        fail_count = 0;
        check_count = 0;
        $display("[gem_tb] scenario '%s' starting", name);
    endfunction

    // `where` rather than `context`: the latter is a SystemVerilog keyword
    // (DPI import qualifier) and cannot be an argument name.
    function automatic void report_fail(string where, string detail);
        fail_count++;
        // Cap the noise: after 20 the pattern is established and the rest is
        // scrollback. The total is still counted and reported at the end.
        if (fail_count <= 20) begin
            $display("FAIL %s: %s", where, detail);
        end else if (fail_count == 21) begin
            $display("FAIL %s: ... further failures suppressed, total reported at end",
                     scenario_name);
        end
    endfunction

    function automatic void note_check();
        check_count++;
    endfunction

    // Formats a beat mismatch with the frame record that explains it.
    function automatic string beat_context(int beatIndex, beat_t expected);
        return $sformatf("%s beat %0d (frame %0d)",
                         scenario_name, beatIndex, expected.frameId);
    endfunction

    // Returns 1 if the scenario passed. The caller decides what to do about
    // it -- but $fatal on failure is what makes `make regress` a gate rather
    // than a report.
    function automatic bit check_done();
        $display("[gem_tb] scenario '%s': %0d checks, %0d failures",
                 scenario_name, check_count, fail_count);
        if (fail_count == 0) begin
            $display("[gem_tb] PASS %s", scenario_name);
            return 1'b1;
        end else begin
            $display("[gem_tb] FAIL %s (%0d failures)", scenario_name, fail_count);
            return 1'b0;
        end
    endfunction

endpackage

`endif

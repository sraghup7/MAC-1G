%BUDGET Stage-1 rate/cycle/FIFO-depth arithmetic for gem_mac.
%   Re-derives every number in PROJECT_SPEC.md B.3 and B.3a from first
%   principles, so the spec's numbers are checked by running this script,
%   not just typed into a table.
%
%   Frame-geometry and datapath constants (MIN_FRAME_BYTES, MAX_FRAME_BYTES,
%   IFG_BYTES, DATA_WIDTH, FCS_BYTES, RX_FIFO_DEPTH) are pulled live from
%   rtl/gem_mac_params.vh via GEM.PARAMS, the same way the golden model does
%   -- this script does not keep a second hardcoded copy of a number the RTL
%   already defines, for the same reason GEM.PARAMS itself gives: two copies
%   of one constant is a bug that looks exactly like a real failure. That
%   now includes SYS_CLK_HZ and RX_LATENCY_MAX_CYCLES, which the header
%   carries too. The PHY-datasheet and IEEE-802.3 numbers below (clock ppm
%   tolerance, TsetupT/TholdT windows) have no RTL parameter to read, since
%   they describe the environment the design sits in, not the design itself,
%   so they stay local.

here = fileparts(mfilename('fullpath'));           % .../spec
repoRoot = fileparts(here);                         % .../
addpath(fullfile(repoRoot, 'model'));

p = gem.params();

lineRateBps       = 1e9;      % 1000BASE-T, R18
clockHz           = double(p.SYS_CLK_HZ);            % GEM_SYS_CLK_HZ
clockPeriodNs      = 1e9 / clockHz;                  % 8.0 ns at 125 MHz

minFrameBytes     = double(p.MIN_FRAME_BYTES);       % 802.3 Table 4-2
maxFrameBytes     = double(p.MAX_FRAME_BYTES);       % 802.3 Table 4-2
ifgBytes          = double(p.IFG_BYTES);             % 96 bit-times, Table 4-2
sfdBytes          = 1;                                % GEM_SFD_OCTET is the pattern, not a count
preambleBytes     = double(p.PREAMBLE_BYTES) + sfdBytes;
dataWidthBits     = double(p.DATA_WIDTH);            % AXI-S tdata width, R15
fcsBytes          = double(p.FCS_BYTES);             % 802.3 Clause 3.2.9
fifoDepthChosen   = double(p.RX_FIFO_DEPTH);         % 1 BRAM18 @ 8-bit width

rgmiiClockTolerancePpm = 100;   % 802.3 Clause 40, 1000BASE-T, each side
cdcSyncLatencyBytes    = 4;     % dual-flop gray-code pointer sync, w/ margin

phyTxSetupHoldNs  = [1.2, 2.0]; % KSZ9031RNX datasheet Table 19, TsetupT/TholdT
phyRxSetupHoldNs  = [1.0, 2.0]; % KSZ9031RNX datasheet Table 19, TsetupR/TholdR
phyRxDefaultDelayNs = 1.2;      % KSZ9031RNX default RX_CLK-to-RXD delay

r21LatencyCeilingCycles = double(p.RX_LATENCY_MAX_CYCLES);   % GEM_RX_LATENCY_MAX_CYCLES

% (name, cycles) -- B.1b bottom-up latency check.
%
% "FCS holdback register" added v0.3, found in Stage 3. The RX port
% delivers DA..pad and must not emit the FCS, but cut-through cannot know
% which four octets those are until RX_DV drops -- so the datapath holds
% four octets back and discards whatever is still in the register at end
% of frame. Pure latency, bought to satisfy the delivery contract.
rxPipelineStages = {
    'IDDR capture + nibble combine',      1
    'SFD hunt / deframer FSM',            2
    'FCS holdback register',              fcsBytes
    'CRC-32 verdict generation at EOF',   1
    'Async FIFO CDC (rx_clk -> sys_clk)', cdcSyncLatencyBytes
    'Registered AXI-S egress stage',      1
};

rateAndCycleBudget(lineRateBps, clockHz, dataWidthBits, minFrameBytes, ...
    preambleBytes, ifgBytes);

fifoDepthDerivation(maxFrameBytes, lineRateBps, rgmiiClockTolerancePpm, ...
    cdcSyncLatencyBytes, fifoDepthChosen);

rgmiiTiming(phyTxSetupHoldNs, phyRxSetupHoldNs, phyRxDefaultDelayNs, ...
    clockPeriodNs);

rxLatencyBudget(rxPipelineStages, r21LatencyCeilingCycles, clockPeriodNs);

fprintf('All derived numbers self-consistent with PROJECT_SPEC.md.\n');


function line(label, value, unit)
%LINE Print one "  label   value+unit" row, matching the table in B.3a.
if nargin < 3
    unit = '';
end
if isnumeric(value)
    valueStr = num2str(value);
else
    valueStr = value;
end
fprintf('  %-38s %s%s\n', label, valueStr, unit);
end


function rateAndCycleBudget(lineRateBps, clockHz, dataWidthBits, ...
    minFrameBytes, preambleBytes, ifgBytes)
fprintf('== B.3 Rate and cycle budget ==\n');
byteRate = lineRateBps / 8;
cyclesPerByte = clockHz / byteRate;
line('Line rate', sprintf('%.3f', lineRateBps/1e9), ' Gbps');
line('Datapath width', dataWidthBits, ' bits/cycle');
line('Cycles per byte', cyclesPerByte);
assert(cyclesPerByte == 1.0, ...
    'gem:budget:cyclesPerByte', ...
    'datapath width does not match line rate at 125 MHz');

minFrameCycleTime = minFrameBytes + preambleBytes + ifgBytes;
frameRate = lineRateBps / (minFrameCycleTime * 8);
line('Worst-case frame rate (min frames)', sprintf('%.3f', frameRate/1e6), ...
    ' Mframes/s');

slackCycles = preambleBytes + ifgBytes;
line('Slack per min-size frame', ...
    sprintf('%d cycles / %d payload-path cycles', slackCycles, minFrameBytes));
fprintf('\n');
end


function fifoDepthDerivation(maxFrameBytes, lineRateBps, ...
    rgmiiClockTolerancePpm, cdcSyncLatencyBytes, fifoDepthChosen)
fprintf('== B.3a RX FIFO depth derivation ==\n');
maxFrameTimeS = (maxFrameBytes * 8) / lineRateBps;
line('Max frame time (1518 B)', sprintf('%.2f', maxFrameTimeS*1e6), ' us');

% Worst case: both sides off in opposite directions.
relativePpm = 2 * rgmiiClockTolerancePpm;
driftBytes = relativePpm * 1e-6 * maxFrameBytes;
line('Worst-case relative clock skew', relativePpm, ' ppm');
line('Drift over one max frame', sprintf('%.3f', driftBytes), ' bytes');

minDepth = driftBytes + cdcSyncLatencyBytes;
line('CDC pointer-sync latency term', cdcSyncLatencyBytes, ' bytes');
line('Derived minimum depth', sprintf('%.2f', minDepth), ' bytes');
line('Chosen depth', fifoDepthChosen, ' entries (1 BRAM18)');
headroom = fifoDepthChosen / minDepth;
line('Headroom over derived minimum', sprintf('%.1fx', headroom));
assert(fifoDepthChosen > minDepth, ...
    'gem:budget:fifoDepth', ...
    'chosen FIFO depth is below the derived minimum');
fprintf('\n');
end


function rgmiiTiming(phyTxSetupHoldNs, phyRxSetupHoldNs, ...
    phyRxDefaultDelayNs, clockPeriodNs)
fprintf('== B.1b RGMII skew targets (KSZ9031RNX datasheet Table 19) ==\n');
txLo = phyTxSetupHoldNs(1); txHi = phyTxSetupHoldNs(2);
rxLo = phyRxSetupHoldNs(1); rxHi = phyRxSetupHoldNs(2);

% Center of the window, not the edge -- a naive 90deg/2.0ns shift sits
% exactly on txHi with zero margin. Centering trades that for equal
% margin on both sides.
txCenterNs = (txLo + txHi) / 2;
txPhaseDeg = (txCenterNs / clockPeriodNs) * 360;
marginLo = txCenterNs - txLo;
marginHi = txHi - txCenterNs;
line('TX required window (TsetupT/TholdT)', sprintf('%g-%g', txLo, txHi), ' ns');
line('Chosen MMCM phase shift for GTX_CLK', sprintf('%.2f', txCenterNs), ...
    sprintf(' ns (-%.0f deg)', txPhaseDeg));
line('Margin to window edges', ...
    sprintf('%.2f ns low / %.2f ns high', marginLo, marginHi));
assert(marginLo > 0 && marginHi > 0, ...
    'gem:budget:txPhaseMargin', ...
    'chosen TX phase shift leaves no margin against the PHY''s window');

line('RX required window (TsetupR/TholdR)', sprintf('%g-%g', rxLo, rxHi), ' ns');
line('PHY default RX_CLK delay (no FPGA action)', phyRxDefaultDelayNs, ' ns');
assert(rxLo <= phyRxDefaultDelayNs && phyRxDefaultDelayNs <= rxHi, ...
    'gem:budget:rxDefaultDelay', ...
    'PHY''s default RX delay falls outside its own required window');
fprintf('\n');
end


function rxLatencyBudget(rxPipelineStages, r21LatencyCeilingCycles, ...
    clockPeriodNs)
fprintf('== B.1b R21 latency budget: bottom-up pipeline sum ==\n');
total = 0;
for k = 1:size(rxPipelineStages, 1)
    name = rxPipelineStages{k, 1};
    cycles = rxPipelineStages{k, 2};
    line(name, cycles, ' cycle(s)');
    total = total + cycles;
end
margin = r21LatencyCeilingCycles / total;
totalNs = total * clockPeriodNs;
ceilingNs = r21LatencyCeilingCycles * clockPeriodNs;
line('Total', sprintf('%d cycles = %.0f ns', total, totalNs));
line('R21 ceiling', sprintf('%d cycles = %.0f ns', r21LatencyCeilingCycles, ceilingNs));
line('Margin', sprintf('%.1fx', margin));
assert(total < r21LatencyCeilingCycles, ...
    'gem:budget:r21Latency', ...
    'bottom-up pipeline sum exceeds R21''s latency ceiling');
fprintf('\n');
end

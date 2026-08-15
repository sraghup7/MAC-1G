function [beats, counters] = expectedBeats(frames)
%EXPECTEDBEATS Golden AXI-Stream egress and R17 counters for received frames.
%   [BEATS, COUNTERS] = GEM.EXPECTEDBEATS(FRAMES) takes the output of
%   GEM.DEFRAME and returns what the RX user port must produce:
%
%       BEATS.data     uint8 row vector, one entry per tvalid/tready beat
%       BEATS.last     logical, true on the final beat of each frame
%       BEATS.user     logical, the R9 verdict; only meaningful where last
%       BEATS.frameId  which frame each beat belongs to, for error messages
%
%       COUNTERS       .rx_ok .rx_badfcs .rx_runt .rx_oversize .rx_rxer (R17)
%
%   ---------------------------------------------------------------------
%   Delivery contract, as decided during Stage 3:
%
%   1. tdata carries DA through pad -- the whole frame except preamble, SFD
%      and FCS. RX tuser stays the single good/bad bit R15 specifies; there is
%      no RX header sideband, so user logic reads the header from the first
%      14 beats.
%
%   2. Every frame ends with exactly one tlast beat at the natural end of its
%      DV burst, whatever went wrong. Errors detectable mid-frame (oversize,
%      RX_ER) do NOT cut the stream short. One delivery rule for all five
%      classes means one tlast timing for the RTL, the assertions and this
%      model to agree on, instead of two.
%
%   3. Frames the deframer never found an SFD for produce no beats at all and
%      touch no counter (R11: inter-frame garbage is ignored silently).
%
%   ---------------------------------------------------------------------
%   Consequence worth being explicit about: because the FCS must not reach the
%   user port, and cut-through cannot know which four octets are the FCS until
%   DV drops, the RX path has to hold the last four octets back in a delay
%   register. That is four cycles of latency the spec's B.1b pipeline sum does
%   not currently list. It does not threaten R21's 32-cycle ceiling, but the
%   spec's own arithmetic should say so rather than be quietly wrong.
%
%   A frame shorter than five octets therefore yields zero beats -- everything
%   it contained was still in the holdback register when DV dropped. It is
%   still counted as a runt. There is no tlast to hang a verdict on, which is
%   correct: nothing was delivered to disown.
%
%   See also GEM.DEFRAME, GEM.PARSEFRAME.

p = gem.params();

data    = uint8([]);
last    = false(1, 0);
user    = false(1, 0);
frameId = zeros(1, 0);

counters = struct('rx_ok', 0, 'rx_badfcs', 0, 'rx_runt', 0, ...
                  'rx_oversize', 0, 'rx_rxer', 0);

for k = 1:numel(frames)
    if ~frames(k).sfdFound
        continue    % R11: never happened, as far as the user port is concerned
    end

    r = gem.parseFrame(frames(k).frameBytes, RxErr=frames(k).rxErr);
    counters.(['rx_' r.class]) = counters.(['rx_' r.class]) + 1;

    n = numel(frames(k).frameBytes);
    if n <= p.FCS_BYTES
        continue    % everything was still in the FCS holdback register
    end

    delivered = frames(k).frameBytes(1 : n - p.FCS_BYTES);
    m = numel(delivered);

    data    = [data,    delivered];             %#ok<AGROW>
    last    = [last,    [false(1, m-1), true]]; %#ok<AGROW>
    user    = [user,    [false(1, m-1), r.verdict]]; %#ok<AGROW>
    frameId = [frameId, repmat(k, 1, m)];       %#ok<AGROW>
end

beats = struct('data', data, 'last', last, 'user', user, 'frameId', frameId);
end

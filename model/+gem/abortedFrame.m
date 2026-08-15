function frame = abortedFrame(payload, da, sa, etherType, stallAt)
%ABORTEDFRAME Golden TX path for an underrun, per spec B.4b.
%   FRAME = GEM.ABORTEDFRAME(PAYLOAD, DA, SA, ETHERTYPE, STALLAT) returns what
%   the MAC must put on the wire when user logic stops supplying payload after
%   STALLAT octets of a frame that has already started.
%
%       .packetBytes  preamble, SFD, header, payload(1:STALLAT), inverted FCS
%       .er           per-octet TX_ER, true only across the four FCS octets
%       .sentPayload  the payload octets that made it out
%       .crc          the CRC over what was actually sent, before inversion
%       .fcs          the four inverted FCS octets, transmission order
%
%   Why this is deterministic, which is what makes it testable at all: the MAC
%   can only have transmitted octets the user actually handed it. Whatever the
%   pipeline depth, an abort after payload octet STALLAT puts exactly header +
%   payload(1:STALLAT) on the wire. A deeper pipeline changes when the MAC
%   notices, not what it has already sent.
%
%   Three things here are decisions from B.4b rather than arithmetic, and each
%   would be a plausible-looking bug if reversed:
%
%   1. NO PADDING. Padding is a frame-completion step (R3); an aborted frame is
%      not being completed. A model that padded to 46 here would demand the RTL
%      emit pad octets it has no reason to generate.
%
%   2. THE FCS IS INVERTED, not random and not omitted. Inverting every bit of
%      a correct CRC is guaranteed to produce an incorrect one -- the inverted
%      value cannot equal the original -- so the receiver's residue check fails
%      deterministically. Omitting the FCS instead would leave a frame whose
%      length alone marks it bad, which is weaker and harder to see.
%
%   3. TX_ER RIDES ONLY THE FCS OCTETS. The abort is detected when the MAC runs
%      dry, and it terminates immediately, so the four inverted FCS octets are
%      the whole abort tail. Asserting TX_ER earlier would mean marking octets
%      that were transmitted correctly.
%
%   The double marking (TX_ER *and* a bad FCS) is deliberate belt-and-braces --
%   see B.4b item 4. TX_ER is the IEEE 802.3 mechanism; the inverted FCS is what
%   makes the frame fail regardless of whether the link partner honours it.
%
%   See also GEM.BUILDFRAME, GEM.GENTXSCENARIO, GEM.CRC32.

arguments
    payload
    da
    sa
    etherType (1,1) {mustBeNumeric}
    stallAt   (1,1) {mustBeNumeric, mustBeNonnegative, mustBeInteger}
end

p = gem.params();

payload = gem.mustBeByteVector(payload, 'payload');
da      = gem.mustBeByteVector(da, 'da');
sa      = gem.mustBeByteVector(sa, 'sa');

if stallAt > numel(payload)
    error('gem:stallBeyondPayload', ...
        'stallAt is %d but the payload is only %d octets.', ...
        stallAt, numel(payload));
end

etherType = uint32(etherType);
header = [da, sa, ...
    uint8(bitand(bitshift(etherType, -8), uint32(255))), ...
    uint8(bitand(etherType, uint32(255)))];

sentPayload = payload(1:stallAt);

% Whatever the MAC managed to transmit is what the FCS covers. No padding --
% see note 1 above.
protectedFields = [header, sentPayload];

crc = gem.crc32(protectedFields);
goodFcs = gem.fcsBytes(crc);

% Bitwise inversion. bitcmp on uint8 is the whole mechanism the RTL needs: one
% XOR with 8'hFF on the FCS output mux.
badFcs = bitcmp(goodFcs);

frameBytes  = [protectedFields, badFcs];
preamble    = repmat(uint8(p.PREAMBLE_OCTET), 1, p.PREAMBLE_BYTES);
packetBytes = [preamble, uint8(p.SFD_OCTET), frameBytes];

% TX_ER across the FCS octets only, aligned to packetBytes.
er = false(1, numel(packetBytes));
er(end - p.FCS_BYTES + 1 : end) = true;

frame = struct( ...
    'payload',     payload, ...
    'sentPayload', sentPayload, ...
    'stallAt',     double(stallAt), ...
    'da',          da, ...
    'sa',          sa, ...
    'etherType',   double(etherType), ...
    'crc',         crc, ...
    'fcs',         badFcs, ...
    'goodFcs',     goodFcs, ...
    'frameBytes',  frameBytes, ...
    'packetBytes', packetBytes, ...
    'er',          er);
end

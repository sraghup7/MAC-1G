function frame = buildFrame(payload, da, sa, etherType, opts)
%BUILDFRAME Golden TX path: user payload to a complete Ethernet II packet.
%   FRAME = GEM.BUILDFRAME(PAYLOAD, DA, SA, ETHERTYPE) returns a struct
%   describing exactly what the TX path (R1-R4) must emit:
%
%       .frameBytes   DA .. FCS inclusive       (this is "the MAC frame")
%       .packetBytes  preamble, SFD, frameBytes (this is what hits the wire)
%       .payload      the payload as supplied, before padding
%       .padBytes     how many zero pad octets were inserted (R3)
%       .fcs          the four FCS octets, transmission order
%       .crc          the CRC-32 word behind them
%
%   Name-value options:
%       PreambleBytes  default 7. Set lower (down to 0) to model a sender that
%                      trims the preamble -- R8 requires the RX path to cope
%                      with anything down to SFD-only, so the generator needs
%                      to be able to produce it.
%
%   Field order and widths follow IEEE 802.3-2022 Clause 3.1 Figure 3-1.
%   Payload longer than 1500 octets is rejected here rather than emitted
%   (R6: "never emit an oversize frame") with error id 'gem:payloadTooLong',
%   so a test can assert the rejection rather than infer it.
%
%   See also GEM.PARSEFRAME, GEM.CRC32, GEM.FCSBYTES.

arguments
    payload
    da
    sa
    etherType (1,1) {mustBeNumeric}
    % Default is [] rather than a sentinel number: MATLAB validates argument
    % defaults, so a -1 "unset" marker would trip mustBeNonnegative on every
    % call that omitted the option.
    opts.PreambleBytes {mustBeNumeric, mustBeNonnegative} = []
end

p = gem.params();

payload = gem.mustBeByteVector(payload, 'payload');
da      = gem.mustBeByteVector(da, 'da');
sa      = gem.mustBeByteVector(sa, 'sa');

if numel(da) ~= p.DA_BYTES
    error('gem:badAddressLength', 'da must be %d octets, got %d.', ...
        p.DA_BYTES, numel(da));
end
if numel(sa) ~= p.SA_BYTES
    error('gem:badAddressLength', 'sa must be %d octets, got %d.', ...
        p.SA_BYTES, numel(sa));
end
if etherType < 0 || etherType > 65535 || etherType ~= floor(etherType)
    error('gem:badEtherType', 'etherType must be an integer in 0..65535.');
end

% R6. The MAC must refuse, not truncate: a truncated frame is a valid-looking
% frame carrying the wrong data, which is strictly worse than no frame.
if numel(payload) > p.MAX_PAYLOAD_BYTES
    error('gem:payloadTooLong', ...
        'Payload is %d octets; R6 caps it at %d.', ...
        numel(payload), p.MAX_PAYLOAD_BYTES);
end

if isempty(opts.PreambleBytes)
    preambleBytes = p.PREAMBLE_BYTES;
else
    preambleBytes = double(opts.PreambleBytes);
end

% Clause 3.2.6: the Length/Type field goes out high-order octet first. This is
% the one field that is big-endian at octet granularity, and it is easy to
% miss because every octet is still LSB-bit-first on the wire.
etherType = uint32(etherType);
header = [da, sa, ...
    uint8(bitand(bitshift(etherType, -8), uint32(255))), ...
    uint8(bitand(etherType, uint32(255)))];

% R3 / Clause 3.2.8. Pad content is unspecified by the standard; zeros are
% conventional and are what the RTL pad generator will emit.
padBytes = max(0, p.MIN_PAYLOAD_BYTES - numel(payload));
padding  = zeros(1, padBytes, 'uint8');

protectedFields = [header, payload, padding];

% R4. The FCS covers DA through Pad -- header, payload and padding -- and
% nothing before DA. Preamble and SFD are part of the packet, not the frame
% (Clause 3.1), and are not protected.
crc = gem.crc32(protectedFields);
fcs = gem.fcsBytes(crc);

frameBytes = [protectedFields, fcs];

preamble = repmat(uint8(p.PREAMBLE_OCTET), 1, preambleBytes);
packetBytes = [preamble, uint8(p.SFD_OCTET), frameBytes];

frame = struct( ...
    'payload',       payload, ...
    'da',            da, ...
    'sa',            sa, ...
    'etherType',     double(etherType), ...
    'padBytes',      padBytes, ...
    'crc',           crc, ...
    'fcs',           fcs, ...
    'frameBytes',    frameBytes, ...
    'packetBytes',   packetBytes, ...
    'preambleBytes', preambleBytes);
end

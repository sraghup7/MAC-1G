function [isGood, residue] = fcsResidue(frameBytes)
%FCSRESIDUE Check a received frame's FCS the way the hardware does.
%   [ISGOOD, RESIDUE] = GEM.FCSRESIDUE(FRAMEBYTES) runs the CRC across the
%   whole frame INCLUDING its own four FCS octets. For any frame whose FCS is
%   correct, the result is a fixed constant -- GEM_CRC32_RESIDUE.
%
%   This is deliberately not "recompute the CRC over the first N-4 bytes and
%   compare against the last 4". Both give the same answer, but only the
%   residue form matches what the RX path will actually build (R9): the CRC
%   accumulator keeps running straight through the FCS field, and at end of
%   frame a single 32-bit comparator produces the good/bad verdict in the same
%   cycle. The alternative needs the accumulator frozen four bytes early, a
%   4-byte delay line to hold the received FCS back, and a decision about what
%   "four bytes early" means when the frame ends unexpectedly.
%
%   The flow doc's rule for a golden model is that it reimplements the
%   hardware's exact arithmetic, not merely an equivalent one. This is that
%   rule applied to the FCS check.
%
%   See also GEM.CRC32, GEM.FCSBYTES, GEM.PARSEFRAME.

p = gem.params();
frameBytes = gem.mustBeByteVector(frameBytes, 'frameBytes');

residue = gem.crc32(frameBytes);
isGood  = (residue == uint32(p.CRC32_RESIDUE));
end

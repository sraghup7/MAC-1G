# Program the FPGA over JTAG (volatile - lost on power cycle; that's
# correct for Stage 2/Tier A bring-up, which only needs to prove the JTAG
# path and the board, not survive a reboot).
#
# Usage: vivado -mode batch -source scripts/program.tcl -tclargs <bit_path>

if {[llength $argv] < 1} {
    puts "Usage: vivado -mode batch -source scripts/program.tcl -tclargs <path/to/bitstream.bit>"
    exit 1
}
set BIT [lindex $argv 0]

open_hw_manager
connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $BIT $dev
program_hw_devices $dev

puts "==> Programmed $BIT onto $dev"

close_hw_target
disconnect_hw_server

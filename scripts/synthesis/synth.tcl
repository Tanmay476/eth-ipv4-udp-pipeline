# =============================================================================
# synth.tcl — Xilinx Vivado synthesis & implementation script
#              Ethernet/IPv4/UDP Packet Processor
#
# Usage (from project root):
#   vivado -mode batch -source scripts/synthesis/synth.tcl
#
# Optional overrides (pass via -tclargs):
#   vivado -mode batch -source scripts/synthesis/synth.tcl \
#          -tclargs --part xc7a100tcsg324-1 --jobs 4
#
# Outputs (written to impl/):
#   impl/post_synth.dcp         — post-synthesis checkpoint
#   impl/post_impl.dcp          — post-implementation checkpoint
#   impl/timing_summary.rpt     — timing summary (setup/hold)
#   impl/utilization.rpt        — LUT/FF/BRAM utilization
#   impl/power.rpt              — power estimate
#   impl/route_status.rpt       — routing completion status
#
# NOTE: Bitstream generation is commented out because it requires
#       a pin-assignment constraints file (pinout.xdc). Add your
#       board-specific pinout constraints and uncomment the
#       write_bitstream call at the bottom of this script.
# =============================================================================

# ── Default parameters ────────────────────────────────────────────────────────
# Target: Artix-7 100T on Digilent Nexys A7 / Basys 3 (change as needed)
set part    "xc7a100tcsg324-1"
set top     "packet_processor_top"
set jobs    4

# ── Parse -tclargs overrides ──────────────────────────────────────────────────
if { [llength $argv] > 0 } {
    for { set i 0 } { $i < [llength $argv] } { incr i } {
        set arg [lindex $argv $i]
        switch -- $arg {
            --part  { incr i; set part  [lindex $argv $i] }
            --top   { incr i; set top   [lindex $argv $i] }
            --jobs  { incr i; set jobs  [lindex $argv $i] }
            default { puts "WARNING: Unknown argument: $arg" }
        }
    }
}

# ── Resolve project root (directory containing this script's parent) ──────────
set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize "${script_dir}/../.."]
set impl_dir   "${proj_root}/impl"
set constr_dir "${proj_root}/constraints"

puts "============================================================"
puts " Ethernet/IPv4/UDP Packet Processor — Vivado Synthesis"
puts "============================================================"
puts " Part        : ${part}"
puts " Top module  : ${top}"
puts " Project root: ${proj_root}"
puts " Output dir  : ${impl_dir}"
puts "============================================================"

# ── Create output directory ───────────────────────────────────────────────────
file mkdir ${impl_dir}

# ── RTL source files (compilation order matters) ─────────────────────────────
set rtl_files [list \
    "${proj_root}/rtl/axi_stream/axi_stream_if.sv"   \
    "${proj_root}/rtl/ethernet/eth_parser.sv"         \
    "${proj_root}/rtl/ipv4/ipv4_parser.sv"            \
    "${proj_root}/rtl/ipv4/ipv4_checksum.sv"          \
    "${proj_root}/rtl/udp/udp_parser.sv"              \
    "${proj_root}/rtl/udp/udp_checksum.sv"            \
    "${proj_root}/rtl/pipeline/pipeline_ctrl.sv"      \
    "${proj_root}/rtl/top/metadata_formatter.sv"      \
    "${proj_root}/rtl/top/packet_processor_top.sv"    \
]

# ── Read RTL ──────────────────────────────────────────────────────────────────
puts "\n[Step 1/6] Reading RTL sources..."
foreach f $rtl_files {
    if { ![file exists $f] } {
        error "RTL file not found: $f"
    }
    read_verilog -sv $f
    puts "  + [file tail $f]"
}

# ── Read constraints ──────────────────────────────────────────────────────────
puts "\n[Step 2/6] Reading constraints..."
set xdc_file "${constr_dir}/timing.xdc"
if { ![file exists $xdc_file] } {
    error "Constraints file not found: $xdc_file"
}
read_xdc $xdc_file
puts "  + timing.xdc"

# ── Synthesis ─────────────────────────────────────────────────────────────────
puts "\n[Step 3/6] Running synthesis (synth_design)..."
synth_design \
    -top    ${top}  \
    -part   ${part} \
    -flatten_hierarchy rebuilt \
    -fsm_extraction     one_hot \
    -keep_equivalent_registers \
    -resource_sharing   off

write_checkpoint -force "${impl_dir}/post_synth.dcp"
report_timing_summary -file "${impl_dir}/timing_post_synth.rpt"
report_utilization    -file "${impl_dir}/utilization_post_synth.rpt"

puts "  Synthesis complete. Checkpoint: ${impl_dir}/post_synth.dcp"

# ── Optimization ─────────────────────────────────────────────────────────────
puts "\n[Step 4/6] Running opt_design..."
opt_design

# ── Placement ─────────────────────────────────────────────────────────────────
puts "\n[Step 5/6] Running place_design..."
place_design -directive ExploreSpreadLogic

phys_opt_design

write_checkpoint -force "${impl_dir}/post_place.dcp"

# ── Routing ───────────────────────────────────────────────────────────────────
puts "\n[Step 6/6] Running route_design..."
route_design -directive Explore

write_checkpoint -force "${impl_dir}/post_impl.dcp"

# ── Reports ───────────────────────────────────────────────────────────────────
puts "\nGenerating implementation reports..."

report_timing_summary \
    -max_paths 10 \
    -report_unconstrained \
    -file "${impl_dir}/timing_summary.rpt"

report_utilization \
    -file "${impl_dir}/utilization.rpt"

report_power \
    -file "${impl_dir}/power.rpt"

report_route_status \
    -file "${impl_dir}/route_status.rpt"

report_drc \
    -file "${impl_dir}/drc.rpt"

# ── Check timing closure ──────────────────────────────────────────────────────
puts "\nChecking timing closure..."
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]

if { $wns >= 0 && $whs >= 0 } {
    puts "============================================================"
    puts " TIMING CLOSURE ACHIEVED"
    puts "   Worst Negative Slack (setup): ${wns} ns"
    puts "   Worst Hold  Slack    (hold) : ${whs} ns"
    puts "============================================================"
} else {
    puts "============================================================"
    puts " WARNING: TIMING NOT MET"
    puts "   Worst Negative Slack (setup): ${wns} ns"
    puts "   Worst Hold  Slack    (hold) : ${whs} ns"
    puts "   Review ${impl_dir}/timing_summary.rpt for details."
    puts "============================================================"
}

# ── Bitstream (uncomment after adding pinout constraints) ─────────────────────
# NOTE: To generate a bitstream, add a pinout constraints file (e.g.
# constraints/pinout.xdc) with your board's I/O assignments, then
# uncomment the following:
#
# read_xdc "${constr_dir}/pinout.xdc"
# write_bitstream -force "${impl_dir}/${top}.bit"
# write_debug_probes -force "${impl_dir}/${top}.ltx"
# puts "Bitstream written to ${impl_dir}/${top}.bit"

puts "\nSynthesis and implementation complete."
puts "Reports are in: ${impl_dir}/"

# =============================================================================
# Intel Quartus Prime equivalent (reference — run separately with quartus_sh)
# =============================================================================
# quartus_sh --flow compile packet_processor_top
#
# Or via Tcl:
#   package require ::quartus::flow
#   load_package flow
#   set_global_assignment -name FAMILY "Cyclone V"
#   set_global_assignment -name DEVICE 5CSEMA5F31C6
#   set_global_assignment -name TOP_LEVEL_ENTITY packet_processor_top
#   foreach f $rtl_files { set_global_assignment -name SYSTEMVERILOG_FILE $f }
#   set_global_assignment -name SDC_FILE constraints/timing.sdc
#   execute_flow -compile

# =============================================================================
# timing.xdc — Timing constraints for Ethernet/IPv4/UDP Packet Processor
#
# Target clock: 100 MHz (10.0 ns period)
# The byte-serial pipeline stages (eth_parser → ipv4_parser → udp_parser)
# each complete header parsing in one byte per cycle, so all logic is
# single-cycle registered. The checksum carry-fold finalization uses a
# two-register chain that is explicitly relaxed with a multicycle path.
# =============================================================================

# ── Primary clock ─────────────────────────────────────────────────────────────
# Define the main system clock on the clk port.
#   10.0 ns → 100 MHz
create_clock -period 10.0 -name clk [get_ports clk]

# ── Input delays (relative to clk) ───────────────────────────────────────────
# Assumes source device launches data 2.0 ns after the clock edge at most,
# and not earlier than 0.5 ns (board trace + source FF delay model).
set_input_delay -clock [get_clocks clk] -max 2.0 \
    [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay -clock [get_clocks clk] -min 0.5 \
    [remove_from_collection [all_inputs] [get_ports clk]]

# ── Output delays (relative to clk) ──────────────────────────────────────────
# Assumes the downstream device requires data 2.0 ns before its clock edge
# and tolerates hold up to 0.5 ns before the clock edge.
set_output_delay -clock [get_clocks clk] -max 2.0 [all_outputs]
set_output_delay -clock [get_clocks clk] -min 0.5 [all_outputs]

# ── False path: asynchronous active-low reset ─────────────────────────────────
# rst_n is assumed to be de-asserted synchronously (or via a synchroniser),
# but the assertion edge is asynchronous; there is no meaningful setup/hold
# requirement on the assertion path itself.
set_false_path -from [get_ports rst_n]

# ── Multicycle paths: checksum carry-fold finalization ────────────────────────
# ipv4_checksum and udp_checksum both use a two-stage registered carry-fold
# to reduce the critical path of the final ones-complement reduction.
# The carry-fold registers are clocked every cycle but the combinational
# path from the first fold stage to the second fold register spans two
# pipeline stages in the checksum modules.
#
set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *carry_fold_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *carry_fold_reg*}]
set_multicycle_path 1 -hold  \
    -from [get_cells -hierarchical -filter {NAME =~ *carry_fold_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *carry_fold_reg*}]

# Also relax the accumulator → checksum_ok path: the checksum valid flag is
# only consumed the cycle after the fold completes (registered output).
set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *checksum*accum*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *checksum_ok*}]
set_multicycle_path 1 -hold  \
    -from [get_cells -hierarchical -filter {NAME =~ *checksum*accum*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *checksum_ok*}]
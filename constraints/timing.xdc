# =============================================================================
# timing.xdc — Timing constraints for Ethernet/IPv4/UDP Packet Processor
#
# Target clock: 100 MHz (10.0 ns period)
# The byte-serial pipeline stages (eth_parser → ipv4_parser → udp_parser)
# each complete header parsing in one byte per cycle, so all logic is
# single-cycle registered, including the checksum carry-fold finalization.
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

# ── No multicycle exception on the checksum carry-fold ─────────────────────────
# ipv4_checksum and udp_checksum fold the running sum (fold1/fold2) fully
# combinationally between the running_sum register and the output register —
# there is no intermediate carry_fold_reg pipeline stage in the current RTL,
# so this path is a normal single-cycle register-to-register path and must
# meet the full 10.0 ns clock period like everything else. Per the timing
# comments in ipv4_checksum.sv, the fold logic is ~2.5-3.0 ns and meets this
# budget without relaxation. A previous version of this constraint applied
# set_multicycle_path against *carry_fold_reg*/*checksum_ok* cell name
# patterns that don't exist in the design (get_cells matched nothing), which
# would have silently masked a real setup violation had one existed. If the
# checksum path is later pipelined (splitting FINALIZE into two states, per
# the TODO in ipv4_checksum.sv), reintroduce a multicycle exception here
# naming the actual pipeline registers.
#!/bin/bash
# =============================================================================
# run_sim.sh — Simulation script for Ethernet/IPv4/UDP Packet Processor
#
# Usage:
#   ./scripts/simulation/run_sim.sh [OPTIONS]
#
# Options:
#   --sim <tool>     Simulator to use: verilator|iverilog|questa|modelsim|vcs|xsim
#                    Default: verilator (if available), else iverilog, else xsim
#   --wave           Enable VCD waveform dump (sim/tb_packet_processor.vcd)
#   --test <suite>   Run a specific test suite: basic|error|throughput|all
#                    Default: all
#   --clean          Remove sim/ directory before running
#   --help           Show this help message
#
# Supported simulators:
#   verilator  — open-source, no license required (recommended)
#   iverilog   — open-source fallback (Icarus Verilog)
#   questa     — Mentor Questa / ModelSim-SE (vlog/vsim)
#   modelsim   — Mentor ModelSim (vlog/vsim, same flow as questa)
#   vcs        — Synopsys VCS
#   xsim       — Vivado's bundled simulator (xvlog/xelab/xsim); no separate
#                license needed beyond a Vivado install
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SIMULATOR=""
WAVE=0
TEST_SUITE="all"
CLEAN=0

# ── Script / project root paths ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SIM_DIR="${PROJECT_ROOT}/sim"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ── Helper functions ──────────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sim)      SIMULATOR="$2"; shift 2 ;;
        --wave)     WAVE=1;         shift   ;;
        --test)     TEST_SUITE="$2"; shift 2 ;;
        --clean)    CLEAN=1;        shift   ;;
        --help|-h)  usage ;;
        *) die "Unknown option: $1  (run with --help for usage)" ;;
    esac
done

# ── Auto-detect simulator if not specified ────────────────────────────────────
if [[ -z "${SIMULATOR}" ]]; then
    if   command -v verilator &>/dev/null; then SIMULATOR="verilator"
    elif command -v iverilog  &>/dev/null; then SIMULATOR="iverilog"
    elif command -v vlog      &>/dev/null; then SIMULATOR="questa"
    elif command -v vcs       &>/dev/null; then SIMULATOR="vcs"
    elif command -v xvlog     &>/dev/null; then SIMULATOR="xsim"
    else die "No supported simulator found. Install verilator or iverilog, source a Vivado environment for xsim, or specify one with --sim."
    fi
    info "Auto-detected simulator: ${SIMULATOR}"
fi

# ── Validate test suite ───────────────────────────────────────────────────────
case "${TEST_SUITE}" in
    basic|error|throughput|all) ;;
    *) die "Unknown test suite '${TEST_SUITE}'. Choose: basic|error|throughput|all" ;;
esac

# ── Build RTL file list ───────────────────────────────────────────────────────
RTL_FILES=(
    "${PROJECT_ROOT}/rtl/axi_stream/axi_stream_if.sv"
    "${PROJECT_ROOT}/rtl/ethernet/eth_parser.sv"
    "${PROJECT_ROOT}/rtl/ipv4/ipv4_parser.sv"
    "${PROJECT_ROOT}/rtl/ipv4/ipv4_checksum.sv"
    "${PROJECT_ROOT}/rtl/udp/udp_parser.sv"
    "${PROJECT_ROOT}/rtl/udp/udp_checksum.sv"
    "${PROJECT_ROOT}/rtl/pipeline/pipeline_ctrl.sv"
    "${PROJECT_ROOT}/rtl/top/metadata_formatter.sv"
    "${PROJECT_ROOT}/rtl/top/packet_processor_top.sv"
)

TB_FILES=(
    "${PROJECT_ROOT}/tb/packet_gen/packet_generator.sv"
    "${PROJECT_ROOT}/tb/packet_gen/scoreboard.sv"
    "${PROJECT_ROOT}/tb/tb_packet_processor.sv"
)

ALL_FILES=("${RTL_FILES[@]}" "${TB_FILES[@]}")

# ── Prepare simulation directory ──────────────────────────────────────────────
if [[ "${CLEAN}" -eq 1 && -d "${SIM_DIR}" ]]; then
    info "Cleaning simulation directory: ${SIM_DIR}"
    rm -rf "${SIM_DIR}"
fi
mkdir -p "${SIM_DIR}"

# ── VCD flag for testbench ─────────────────────────────────────────────────────
WAVE_DEFINE=""
if [[ "${WAVE}" -eq 1 ]]; then
    WAVE_DEFINE="+define+DUMP_WAVES"
    info "Waveform dumping enabled → ${SIM_DIR}/tb_packet_processor.vcd"
fi

# =============================================================================
# Simulator-specific flows
# =============================================================================

run_verilator() {
    command -v verilator &>/dev/null || die "verilator not found in PATH"
    info "Compiling with Verilator..."

    VERILATOR_FLAGS=(
        --sv
        --binary
        --timing
        --top-module tb_packet_processor
        -Wno-TIMESCALEMOD
        -Wno-STMTDLY
        -Wno-INFINITELOOP
        --trace                             # enable VCD support in binary
        -Mdir "${SIM_DIR}/obj_dir"
        -o "${SIM_DIR}/sim_verilator"
        +incdir+"${PROJECT_ROOT}/tb/tests"
        +incdir+"${PROJECT_ROOT}/tb/packet_gen"
        "${WAVE_DEFINE}"
    )
    # Remove empty elements
    VERILATOR_FLAGS=("${VERILATOR_FLAGS[@]:-}")
    VERILATOR_FLAGS=("${VERILATOR_FLAGS[@]/+define+/+define+}")

    cd "${PROJECT_ROOT}"

    if [[ "${WAVE}" -eq 1 ]]; then
        verilator --sv --binary --timing \
            --top-module tb_packet_processor \
            -Wno-TIMESCALEMOD -Wno-STMTDLY -Wno-INFINITELOOP \
            --trace \
            -Mdir "${SIM_DIR}/obj_dir" \
            -o "${SIM_DIR}/sim_verilator" \
            +incdir+"${PROJECT_ROOT}/tb/tests" \
            +incdir+"${PROJECT_ROOT}/tb/packet_gen" \
            +define+DUMP_WAVES \
            "${ALL_FILES[@]}"
    else
        verilator --sv --binary --timing \
            --top-module tb_packet_processor \
            -Wno-TIMESCALEMOD -Wno-STMTDLY -Wno-INFINITELOOP \
            --trace \
            -Mdir "${SIM_DIR}/obj_dir" \
            -o "${SIM_DIR}/sim_verilator" \
            +incdir+"${PROJECT_ROOT}/tb/tests" \
            +incdir+"${PROJECT_ROOT}/tb/packet_gen" \
            "${ALL_FILES[@]}"
    fi

    info "Running simulation..."
    "${SIM_DIR}/sim_verilator" ${WAVE:+--trace} \
        ${WAVE:+--trace-file "${SIM_DIR}/tb_packet_processor.vcd"} 2>&1 | tee "${SIM_DIR}/sim.log"
}

run_iverilog() {
    command -v iverilog &>/dev/null || die "iverilog not found in PATH"
    command -v vvp      &>/dev/null || die "vvp not found in PATH"
    info "Compiling with Icarus Verilog (iverilog)..."

    IFLAGS=(
        -g2012
        -o "${SIM_DIR}/sim.vvp"
        -I "${PROJECT_ROOT}/tb/tests"
        -I "${PROJECT_ROOT}/tb/packet_gen"
    )
    [[ "${WAVE}" -eq 1 ]] && IFLAGS+=(-DDUMP_WAVES)

    iverilog "${IFLAGS[@]}" "${ALL_FILES[@]}"

    info "Running simulation..."
    vvp "${SIM_DIR}/sim.vvp" 2>&1 | tee "${SIM_DIR}/sim.log"
}

run_questa() {
    command -v vlog &>/dev/null || die "vlog (Questa/ModelSim) not found in PATH"
    command -v vsim &>/dev/null || die "vsim (Questa/ModelSim) not found in PATH"
    info "Compiling with Questa/ModelSim (vlog)..."

    cd "${SIM_DIR}"
    vlog -sv \
        +incdir+"${PROJECT_ROOT}/tb/tests" \
        +incdir+"${PROJECT_ROOT}/tb/packet_gen" \
        ${WAVE:++define+DUMP_WAVES} \
        "${ALL_FILES[@]}"

    info "Running simulation..."
    vsim -c tb_packet_processor \
        -do "run -all; quit" 2>&1 | tee sim.log
    cd "${PROJECT_ROOT}"
}

run_vcs() {
    command -v vcs &>/dev/null || die "vcs not found in PATH"
    info "Compiling with Synopsys VCS..."

    cd "${PROJECT_ROOT}"
    vcs -sverilog -full64 \
        +incdir+"${PROJECT_ROOT}/tb/tests" \
        +incdir+"${PROJECT_ROOT}/tb/packet_gen" \
        ${WAVE:++define+DUMP_WAVES} \
        -o "${SIM_DIR}/sim_vcs" \
        "${ALL_FILES[@]}"

    info "Running simulation..."
    "${SIM_DIR}/sim_vcs" 2>&1 | tee "${SIM_DIR}/sim.log"
}

run_xsim() {
    command -v xvlog &>/dev/null || die "xvlog not found in PATH (source a Vivado settings64.sh / setup_env.sh first)"
    command -v xelab &>/dev/null || die "xelab not found in PATH"
    command -v xsim  &>/dev/null || die "xsim not found in PATH"

    cd "${PROJECT_ROOT}"

    info "Compiling with Vivado xsim (xvlog)..."
    XVLOG_FLAGS=(
        -sv
        -i "${PROJECT_ROOT}/tb/tests"
        -i "${PROJECT_ROOT}/tb/packet_gen"
        --log "${SIM_DIR}/xvlog.log"
    )
    [[ "${WAVE}" -eq 1 ]] && XVLOG_FLAGS+=(-d DUMP_WAVES)

    xvlog "${XVLOG_FLAGS[@]}" "${ALL_FILES[@]}"

    info "Elaborating (xelab)..."
    xelab tb_packet_processor -s tb_snap --log "${SIM_DIR}/xelab.log"

    info "Running simulation..."
    xsim tb_snap -R --log "${SIM_DIR}/xsim.log" 2>&1 | tee "${SIM_DIR}/sim.log"
}

# =============================================================================
# Main
# =============================================================================

info "Project root : ${PROJECT_ROOT}"
info "Simulator    : ${SIMULATOR}"
info "Test suite   : ${TEST_SUITE}"
info "Waveforms    : $([ "${WAVE}" -eq 1 ] && echo yes || echo no)"
echo ""

case "${SIMULATOR}" in
    verilator)              run_verilator ;;
    iverilog)               run_iverilog  ;;
    questa|modelsim)        run_questa    ;;
    vcs)                    run_vcs       ;;
    xsim)                   run_xsim      ;;
    *) die "Unsupported simulator '${SIMULATOR}'" ;;
esac

SIM_EXIT=${PIPESTATUS[0]:-$?}

echo ""
if grep -q "PASS" "${SIM_DIR}/sim.log" 2>/dev/null && ! grep -q "FAIL" "${SIM_DIR}/sim.log" 2>/dev/null; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  SIMULATION PASSED${NC}"
    echo -e "${GREEN}========================================${NC}"
elif grep -q "FAIL" "${SIM_DIR}/sim.log" 2>/dev/null; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}  SIMULATION FAILED — check ${SIM_DIR}/sim.log${NC}"
    echo -e "${RED}========================================${NC}"
    exit 1
else
    echo -e "${YELLOW}  Simulation complete — review ${SIM_DIR}/sim.log for results${NC}"
fi

if [[ "${WAVE}" -eq 1 && -f "${SIM_DIR}/tb_packet_processor.vcd" ]]; then
    info "Waveform written to ${SIM_DIR}/tb_packet_processor.vcd"
    info "Open with: gtkwave ${SIM_DIR}/tb_packet_processor.vcd"
fi

exit ${SIM_EXIT}

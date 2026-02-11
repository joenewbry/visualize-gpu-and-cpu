#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMC_BIN="$SCRIPT_DIR/smc_temp"
SMC_SRC="$SCRIPT_DIR/smc_temp.swift"
CORE_BIN="$SCRIPT_DIR/cpu_cores"
CORE_SRC="$SCRIPT_DIR/cpu_cores.swift"
INTERVAL=2

# Colors
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
MAGENTA=$'\033[35m'
RESET=$'\033[0m'

# Temp file for per-core CPU data (collected in background)
CORE_TMP=$(mktemp /tmp/cpu_cores.XXXXXX)

cleanup() {
    rm -f "$CORE_TMP" 2>/dev/null
    tput cnorm 2>/dev/null
    printf "\n%s%s%s\n" "$DIM" "Exited." "$RESET"
    exit 0
}
trap cleanup INT TERM

# Auto-compile Swift helpers if needed
if [[ ! -x "$SMC_BIN" ]]; then
    echo "Compiling smc_temp helper..."
    swiftc -O "$SMC_SRC" -o "$SMC_BIN" -framework IOKit -framework Foundation
    echo "Done."
fi
if [[ ! -x "$CORE_BIN" ]]; then
    echo "Compiling cpu_cores helper..."
    swiftc -O "$CORE_SRC" -o "$CORE_BIN"
    echo "Done."
fi

# Detect CPU topology once
NUM_E_CORES=4   # M2 Pro: cores 0-3 are efficiency
NUM_TOTAL_CORES=$(sysctl -n hw.logicalcpu)
NUM_P_CORES=$((NUM_TOTAL_CORES - NUM_E_CORES))
GPU_NUM_CORES=$(ioreg -r -c AGXAccelerator 2>/dev/null | grep -o '"num_cores"=[0-9]*' | grep -o '[0-9]*$' || echo "?")
CHIP_NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")

BOX_W=56  # inner width between │ markers
W=26      # main bar character width
CORE_W=12 # per-core bar width

# Strip ANSI escapes and count visible width
vislen() {
    local stripped
    stripped=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
    echo ${#stripped}
}

# Print a box row: │<content padded to BOX_W>│
row() {
    local content="$1"
    local vlen
    vlen=$(vislen "$content")
    local pad=$((BOX_W - vlen))
    if (( pad < 0 )); then pad=0; fi
    printf '%s│%s%s%*s%s│%s\n' "$BOLD" "$RESET" "$content" "$pad" "" "$BOLD" "$RESET"
}

empty_row() {
    printf "%s│%s%*s%s│%s\n" "$BOLD" "$RESET" "$BOX_W" "" "$BOLD" "$RESET"
}

divider_row() {
    local line
    line=$(printf '┈%.0s' $(seq 1 $BOX_W))
    printf "%s│%s%s%s%s│%s\n" "$BOLD" "$RESET" "$DIM" "$line" "$BOLD" "$RESET"
}

# Bar: outputs colored bar string of given width
make_bar() {
    local val=$1 max=$2 width=$3
    local filled pct color
    filled=$(awk "BEGIN { v=int(($val / $max) * $width); if(v<0)v=0; if(v>$width)v=$width; print v }")
    local empty=$((width - filled))
    pct=$(awk "BEGIN { printf \"%.0f\", ($val / $max) * 100 }")
    color="$GREEN"
    if (( pct > 80 )); then color="$RED"
    elif (( pct > 50 )); then color="$YELLOW"
    fi
    BAR_STR="$color"
    local j
    for ((j=0; j<filled; j++)); do BAR_STR+='█'; done
    BAR_STR+="$DIM"
    for ((j=0; j<empty; j++)); do BAR_STR+='░'; done
    BAR_STR+="$RESET"
}

# Color for temperature value
temp_col() {
    local temp=${1%%.*}
    if (( temp >= 80 )); then echo "$RED"
    elif (( temp >= 60 )); then echo "$YELLOW"
    else echo "$GREEN"
    fi
}

# Format bytes to human readable
fmt_bytes() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        awk "BEGIN { printf \"%.1fG\", $bytes / 1073741824 }"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN { printf \"%.0fM\", $bytes / 1048576 }"
    else
        awk "BEGIN { printf \"%.0fK\", $bytes / 1024 }"
    fi
}

# Get total memory once
MEM_TOTAL_BYTES=$(sysctl -n hw.memsize)
MEM_TOTAL_GB=$(awk "BEGIN { printf \"%.0f\", $MEM_TOTAL_BYTES / 1073741824 }")

tput civis  # hide cursor

while true; do
    # --- Collect data ---

    # Start per-core CPU sampling in background (~500ms)
    "$CORE_BIN" > "$CORE_TMP" 2>/dev/null &
    core_pid=$!

    # Aggregate CPU (runs in parallel with cpu_cores)
    cpu_line=$(top -l 2 -s 0 -n 0 2>/dev/null | grep "CPU usage" | tail -1)
    cpu_user=$(echo "$cpu_line" | awk -F'[ %]+' '{print $3}')
    cpu_sys=$(echo "$cpu_line" | awk -F'[ %]+' '{print $5}')
    cpu_idle=$(echo "$cpu_line" | awk -F'[ %]+' '{print $7}')
    cpu_used=$(awk "BEGIN { printf \"%.1f\", $cpu_user + $cpu_sys }")

    # GPU utilization
    gpu_raw=$(ioreg -r -c AGXAccelerator 2>/dev/null || true)
    gpu_util=$(echo "$gpu_raw" | grep -o '"Device Utilization %"=[0-9]*' | grep -o '[0-9]*$')
    gpu_render=$(echo "$gpu_raw" | grep -o '"Renderer Utilization %"=[0-9]*' | grep -o '[0-9]*$')
    gpu_tiler=$(echo "$gpu_raw" | grep -o '"Tiler Utilization %"=[0-9]*' | grep -o '[0-9]*$')
    gpu_util=${gpu_util:-0}
    gpu_render=${gpu_render:-0}
    gpu_tiler=${gpu_tiler:-0}

    # GPU memory from PerformanceStatistics
    gpu_mem_alloc=$(echo "$gpu_raw" | grep -o '"Alloc system memory"=[0-9]*' | grep -o '[0-9]*$' || echo "0")
    gpu_mem_inuse=$(echo "$gpu_raw" | grep -o '"In use system memory"=[0-9]*' | head -1 | grep -o '[0-9]*$' || echo "0")

    # System Memory
    mem_line=$(top -l 1 -s 0 -n 0 2>/dev/null | grep "PhysMem")
    mem_used_raw=$(echo "$mem_line" | awk '{print $2}')
    mem_used_num=${mem_used_raw%%[A-Za-z]*}
    mem_used_unit=${mem_used_raw##*[0-9]}
    if [[ "$mem_used_unit" == "M" || "$mem_used_unit" == "m" ]]; then
        mem_used_gb=$(awk "BEGIN { printf \"%.1f\", $mem_used_num / 1024 }")
    else
        mem_used_gb=$mem_used_num
    fi

    # Swap
    swap_raw=$(sysctl vm.swapusage 2>/dev/null)
    swap_used=$(echo "$swap_raw" | awk '{print $7}' | tr -d 'M')
    swap_total=$(echo "$swap_raw" | awk '{print $4}' | tr -d 'M')

    # Temps
    cpu_temp="" gpu_temp=""
    if [[ -x "$SMC_BIN" ]]; then
        temp_out=$("$SMC_BIN" 2>/dev/null || true)
        cpu_temp=$(echo "$temp_out" | grep "CPU_TEMP_AVG" | cut -d= -f2)
        gpu_temp=$(echo "$temp_out" | grep "GPU_TEMP_AVG" | cut -d= -f2)
    fi

    # Wait for per-core data and parse
    wait "$core_pid" 2>/dev/null || true

    # Read core data into indexed variables (robust for bash 3.2+)
    num_cores=0
    while IFS='=' read -r key val; do
        if [[ "$key" == CORE* ]]; then
            # Extract core number from key like CORE0, CORE1, etc.
            core_idx=${key#CORE}
            eval "core_val_${core_idx}=\"${val}\""
            num_cores=$((num_cores + 1))
        fi
    done < "$CORE_TMP"

    # --- Draw ---
    clear

    border=$(printf '─%.0s' $(seq 1 $BOX_W))
    echo "${BOLD}╭${border}╮${RESET}"

    # Header
    row "  ${BOLD}${CHIP_NAME}${RESET}  ${DIM}${NUM_E_CORES}E + ${NUM_P_CORES}P cores  GPU ${GPU_NUM_CORES} cores${RESET}"
    divider_row

    # CPU aggregate
    make_bar "$cpu_used" 100 $W
    cpu_pct=$(printf "%5.1f%%" "$cpu_used")
    row "  ${BOLD}${CYAN}CPU${RESET}      ${BAR_STR}  ${cpu_pct}"
    row "  ${DIM}user ${cpu_user}%  sys ${cpu_sys}%  idle ${cpu_idle}%${RESET}"

    # Per-core bars: E-cores and P-cores side by side
    # Left column: E-cores (0..NUM_E_CORES-1), Right column: P-cores (NUM_E_CORES..NUM_TOTAL_CORES-1)
    if (( num_cores > 0 )); then
        max_rows=$NUM_P_CORES
        if (( NUM_E_CORES > NUM_P_CORES )); then
            max_rows=$NUM_E_CORES
        fi

        for ((r=0; r<max_rows; r++)); do
            left_idx=$r
            right_idx=$((r + NUM_E_CORES))

            # Left column (E-core)
            if (( left_idx < NUM_E_CORES )); then
                left_val="0.0"
                eval "left_val=\${core_val_${left_idx}:-0.0}"
                make_bar "$left_val" 100 $CORE_W
                left_bar="$BAR_STR"
                left_pct=$(printf "%3.0f%%" "$left_val")
                left_str="  ${DIM}E${RESET}$(printf '%d' $left_idx) ${left_bar} ${left_pct}"
            else
                # Empty left column
                left_str=$(printf "  %*s" 19 "")
            fi

            # Right column (P-core)
            if (( right_idx < NUM_TOTAL_CORES )); then
                right_val="0.0"
                eval "right_val=\${core_val_${right_idx}:-0.0}"
                make_bar "$right_val" 100 $CORE_W
                right_bar="$BAR_STR"
                right_pct=$(printf "%3.0f%%" "$right_val")
                right_str="  ${BOLD}P${RESET}$(printf '%d' $right_idx) ${right_bar} ${right_pct}"
            else
                right_str=""
            fi

            row "${left_str}${right_str}"
        done
    fi
    divider_row

    # GPU metrics
    make_bar "$gpu_util" 100 $W
    gpu_pct=$(printf "%3s%%" "$gpu_util")
    row "  ${BOLD}${CYAN}GPU${RESET}      ${BAR_STR}  ${gpu_pct}"
    make_bar "$gpu_render" 100 $W
    render_pct=$(printf "%3s%%" "$gpu_render")
    row "  ${DIM}Render${RESET}   ${BAR_STR}  ${render_pct}"
    make_bar "$gpu_tiler" 100 $W
    tiler_pct=$(printf "%3s%%" "$gpu_tiler")
    row "  ${DIM}Tiler${RESET}    ${BAR_STR}  ${tiler_pct}"

    # GPU VRAM
    if [[ "$gpu_mem_alloc" != "0" ]]; then
        alloc_str=$(fmt_bytes "$gpu_mem_alloc")
        inuse_str=$(fmt_bytes "$gpu_mem_inuse")
        row "  ${DIM}VRAM  alloc: ${RESET}${alloc_str}${DIM}  in use: ${RESET}${inuse_str}"
    fi
    divider_row

    # System Memory
    mem_pct=$(awk "BEGIN { printf \"%.1f\", ($mem_used_gb / $MEM_TOTAL_GB) * 100 }")
    make_bar "$mem_pct" 100 $W
    mem_pct_str=$(printf "%3.0f%%" "$mem_pct")
    row "  ${BOLD}${CYAN}MEM${RESET}      ${BAR_STR}  ${mem_used_gb}G/${MEM_TOTAL_GB}G"

    if [[ -n "$swap_used" ]] && awk "BEGIN { exit ($swap_used > 0.01) ? 0 : 1 }" 2>/dev/null; then
        swap_gb=$(awk "BEGIN { printf \"%.1f\", $swap_used / 1024 }")
        swap_total_gb=$(awk "BEGIN { printf \"%.1f\", $swap_total / 1024 }")
        swap_pct=$(awk "BEGIN { if ($swap_total > 0) printf \"%.0f\", ($swap_used / $swap_total) * 100; else print 0 }")
        make_bar "$swap_pct" 100 $W
        row "  ${DIM}Swap${RESET}     ${BAR_STR}  ${swap_gb}G/${swap_total_gb}G"
    else
        row "  ${DIM}swap: none${RESET}"
    fi
    divider_row

    # Temps
    cpu_t_str="${DIM}CPU: --°C${RESET}"
    gpu_t_str="${DIM}GPU: --°C${RESET}"
    if [[ -n "$cpu_temp" ]]; then
        cpu_t_str="$(temp_col "$cpu_temp")CPU: ${cpu_temp}°C${RESET}"
    fi
    if [[ -n "$gpu_temp" ]]; then
        gpu_t_str="$(temp_col "$gpu_temp")GPU: ${gpu_temp}°C${RESET}"
    fi
    row "  ${BOLD}${CYAN}TEMP${RESET}     ${cpu_t_str}    ${gpu_t_str}"

    echo "${BOLD}╰${border}╯${RESET}"
    printf "  %sRefreshing every %ss · Ctrl+C to exit%s\n" "$DIM" "$INTERVAL" "$RESET"

    sleep "$INTERVAL"
done

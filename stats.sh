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

BOX_W=44  # inner width between │ markers
W=20      # main bar character width
CORE_W=10 # per-core bar width

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
    for ((i=0; i<filled; i++)); do BAR_STR+='█'; done
    BAR_STR+="$DIM"
    for ((i=0; i<empty; i++)); do BAR_STR+='░'; done
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

    # GPU
    gpu_raw=$(ioreg -r -c AGXAccelerator 2>/dev/null || true)
    gpu_util=$(echo "$gpu_raw" | grep -o '"Device Utilization %"=[0-9]*' | grep -o '[0-9]*$')
    gpu_render=$(echo "$gpu_raw" | grep -o '"Renderer Utilization %"=[0-9]*' | grep -o '[0-9]*$')
    gpu_tiler=$(echo "$gpu_raw" | grep -o '"Tiler Utilization %"=[0-9]*' | grep -o '[0-9]*$')
    gpu_util=${gpu_util:-0}
    gpu_render=${gpu_render:-0}
    gpu_tiler=${gpu_tiler:-0}

    # Memory
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

    # Wait for per-core data
    wait "$core_pid" 2>/dev/null || true
    core_pcts=()
    num_cores=0
    while IFS='=' read -r key val; do
        if [[ "$key" == CORE* ]]; then
            core_pcts+=("$val")
            num_cores=$((num_cores + 1))
        fi
    done < "$CORE_TMP"

    # --- Draw ---
    clear

    border=$(printf '─%.0s' $(seq 1 $BOX_W))
    echo "${BOLD}╭${border}╮${RESET}"

    # CPU aggregate
    make_bar "$cpu_used" 100 $W
    cpu_pct=$(printf "%5.1f%%" "$cpu_used")
    row "  ${BOLD}${CYAN}CPU${RESET}     ${BAR_STR}  ${cpu_pct}"
    row "  ${DIM}user ${cpu_user}%  sys ${cpu_sys}%  idle ${cpu_idle}%${RESET}"

    # Per-core bars (2 per row, htop-style left/right split)
    if (( num_cores > 0 )); then
        half=$(( (num_cores + 1) / 2 ))
        for ((i=0; i<half; i++)); do
            left=$i
            right=$((i + half))

            left_val="${core_pcts[$left]}"
            make_bar "$left_val" 100 $CORE_W
            left_bar="$BAR_STR"
            left_pct=$(printf "%3.0f%%" "$left_val")
            left_label=$(printf "%2d" "$left")

            if (( right < num_cores )); then
                right_val="${core_pcts[$right]}"
                make_bar "$right_val" 100 $CORE_W
                right_bar="$BAR_STR"
                right_pct=$(printf "%3.0f%%" "$right_val")
                right_label=$(printf "%2d" "$right")
                row "  ${left_label} ${left_bar} ${left_pct}   ${right_label} ${right_bar} ${right_pct}"
            else
                row "  ${left_label} ${left_bar} ${left_pct}"
            fi
        done
    fi
    empty_row

    # GPU metrics (Device as main, Render + Tiler as sub-metrics)
    make_bar "$gpu_util" 100 $W
    gpu_pct=$(printf "%3s%%" "$gpu_util")
    row "  ${BOLD}${CYAN}GPU${RESET}     ${BAR_STR}  ${gpu_pct}"
    make_bar "$gpu_render" 100 $W
    render_pct=$(printf "%3s%%" "$gpu_render")
    row "  ${DIM}Render${RESET}  ${BAR_STR}  ${render_pct}"
    make_bar "$gpu_tiler" 100 $W
    tiler_pct=$(printf "%3s%%" "$gpu_tiler")
    row "  ${DIM}Tiler${RESET}   ${BAR_STR}  ${tiler_pct}"
    empty_row

    # Memory
    mem_pct=$(awk "BEGIN { printf \"%.1f\", ($mem_used_gb / $MEM_TOTAL_GB) * 100 }")
    make_bar "$mem_pct" 100 $W
    row "  ${BOLD}${CYAN}MEM${RESET}     ${BAR_STR}  ${mem_used_gb}G/${MEM_TOTAL_GB}G"

    if [[ -n "$swap_used" ]] && awk "BEGIN { exit ($swap_used > 0.01) ? 0 : 1 }" 2>/dev/null; then
        swap_gb=$(awk "BEGIN { printf \"%.1f\", $swap_used / 1024 }")
        swap_total_gb=$(awk "BEGIN { printf \"%.1f\", $swap_total / 1024 }")
        row "  ${DIM}swap ${swap_gb}G / ${swap_total_gb}G${RESET}"
    else
        row "  ${DIM}swap: none${RESET}"
    fi
    empty_row

    # Temps
    cpu_t_str="${DIM}CPU: --°C${RESET}"
    gpu_t_str="${DIM}GPU: --°C${RESET}"
    if [[ -n "$cpu_temp" ]]; then
        cpu_t_str="$(temp_col "$cpu_temp")CPU: ${cpu_temp}°C${RESET}"
    fi
    if [[ -n "$gpu_temp" ]]; then
        gpu_t_str="$(temp_col "$gpu_temp")GPU: ${gpu_temp}°C${RESET}"
    fi
    row "  ${BOLD}${CYAN}TEMP${RESET}    ${cpu_t_str}  ${gpu_t_str}"

    echo "${BOLD}╰${border}╯${RESET}"
    printf "  %sRefreshing every %ss · Ctrl+C to exit%s\n" "$DIM" "$INTERVAL" "$RESET"

    sleep "$INTERVAL"
done

#!/usr/bin/env bash
# vim: noai:ts=4:sw=4:expandtab
# shellcheck disable=SC2015,SC2016
#
# TrueNAS Proxmox VE Plugin Installer
# Interactive installation, update, and configuration wizard

set -euo pipefail

# ============================================================================
# CONSTANTS AND CONFIGURATION
# ============================================================================

readonly INSTALLER_VERSION="1.1.0"
readonly GITHUB_REPO="WarlockSyno/truenasplugin"
readonly PLUGIN_FILE="/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm"
readonly STORAGE_CFG="/etc/pve/storage.cfg"
readonly BACKUP_DIR="/var/lib/truenas-plugin-backups"
readonly LOG_FILE="/var/log/truenas-installer.log"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_USER_CANCEL=2

# Escape sequence helper
esc() {
    case $1 in
        CUU) printf '\033[%sA' "${2:-1}" ;;      # cursor up
        CUD) printf '\033[%sB' "${2:-1}" ;;      # cursor down
        CUF) printf '\033[%sC' "${2:-1}" ;;      # cursor forward
        CUB) printf '\033[%sD' "${2:-1}" ;;      # cursor backward
        SCP) printf '\033[s' ;;                   # save cursor position
        RCP) printf '\033[u' ;;                   # restore cursor position
        SGR) printf '\033[%sm' "$2" ;;            # Select Graphic Rendition
    esac
}

# Detect terminal color support
detect_color_support() {
    # Check COLORTERM for truecolor support first (before TTY check)
    if [[ "${COLORTERM:-}" =~ (truecolor|24bit) ]]; then
        echo "truecolor"
        return
    fi

    # Check TERM environment variable for explicit color capability
    if [[ "$TERM" =~ 256color ]]; then
        echo "256"
        return
    elif [[ "$TERM" =~ (xterm-color|.*-256|xterm-16color) ]]; then
        echo "256"
        return
    fi

    # Try tput if available
    local colors
    colors=$(tput colors 2>/dev/null || echo 0)

    if [[ "$colors" -ge 256 ]]; then
        echo "256"
    elif [[ "$colors" -ge 16 ]]; then
        echo "16"
    elif [[ "$colors" -ge 8 ]]; then
        echo "8"
    else
        # Enhanced fallback logic
        # SSH sessions typically support 256 colors
        if [[ -n "$SSH_CLIENT" || -n "$SSH_TTY" || -n "$SSH_CONNECTION" ]]; then
            echo "256"
        elif [[ "$TERM" =~ (xterm|screen|tmux|rxvt|linux|ansi|vt) ]]; then
            echo "16"
        else
            # Check if we have a TTY - if so, assume basic colors
            if [[ -t 1 ]] || [[ -t 0 ]]; then
                echo "16"
            else
                echo "none"
            fi
        fi
    fi
}

# Color support level (can be overridden with INSTALLER_COLORS env var)
readonly COLOR_SUPPORT="${INSTALLER_COLORS:-$(detect_color_support)}"

# Debug: Show detected color support (comment out in production)
# Uncomment the line below to debug color detection:
# echo "DEBUG: COLOR_SUPPORT=$COLOR_SUPPORT TERM=$TERM SSH_CLIENT=${SSH_CLIENT:-none}" >&2

# Color definitions (Dylan Araps style)
c0=$(esc SGR 0)      # reset
c1=$(esc SGR 31)     # red
c2=$(esc SGR 32)     # green
c3=$(esc SGR 33)     # yellow
c4=$(esc SGR 34)     # blue
c5=$(esc SGR 35)     # magenta
c6=$(esc SGR 36)     # cyan
c7=$(esc SGR 37)     # white
c8=$(esc SGR 1)      # bold

# Legacy color compatibility
readonly COLOR_RESET="$c0"
readonly COLOR_RED="$c1"
readonly COLOR_GREEN="$c2"
readonly COLOR_YELLOW="$c3"
readonly COLOR_BLUE="$c4"
readonly COLOR_CYAN="$c6"
readonly COLOR_BOLD="$c8"

# 256-color palette generator
color256() {
    printf '\033[38;5;%dm' "$1"
}

# RGB color (truecolor) generator
rgb() {
    printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"
}

# Generate gradient color for line number (0-based)
# Uses cyan to blue gradient (Neofetch-inspired)
gradient_color() {
    local line_num="$1"
    local total_lines="${2:-15}"

    case "$COLOR_SUPPORT" in
        truecolor)
            # Smooth RGB gradient: cyan (0,255,255) -> blue (0,100,255) -> deep blue (0,50,200)
            local ratio=$((line_num * 100 / total_lines))
            local r=0
            local g=$((255 - ratio * 155 / 100))
            local b=$((255 - ratio * 55 / 100))
            rgb "$r" "$g" "$b"
            ;;
        256)
            # Use 256-color palette: cyan spectrum
            # Colors: 51(cyan) -> 45 -> 39 -> 33(blue)
            local colors=(51 50 49 48 45 44 39 38 33 32 27 26 21 20 19)
            local idx=$((line_num * ${#colors[@]} / total_lines))
            [[ $idx -ge ${#colors[@]} ]] && idx=$((${#colors[@]} - 1))
            color256 "${colors[$idx]}"
            ;;
        16|8)
            # Gradient using basic colors: cyan -> blue
            # Divide into thirds for smooth-ish transition
            local third=$((total_lines / 3))
            if [[ $line_num -lt $third ]]; then
                # First third: bright cyan
                printf '\033[1;36m'
            elif [[ $line_num -lt $((third * 2)) ]]; then
                # Middle third: cyan
                printf '%s' "$c6"
            else
                # Last third: blue
                printf '%s' "$c4"
            fi
            ;;
        *)
            # No color support - return empty string
            :
            ;;
    esac
}

# ============================================================================
# LOGGING AND OUTPUT FUNCTIONS
# ============================================================================

# Global spinner control
SPINNER_PID=""

# Start spinner animation
start_spinner() {
    local spinner_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spinner_pos=0

    # Hide cursor
    printf "\033[?25l" >&2

    # Create a wrapper script that runs spinner in its own process group
    # This ensures all children (including sleep) can be killed together
    local spinner_script="/tmp/.installer-spinner-$$.sh"
    cat > "$spinner_script" << 'SPINNER_EOF'
#!/bin/bash
# Create new process group
set -m

# Trap to kill entire process group on exit
cleanup() {
    # Kill all processes in this process group
    kill -- -$$ 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT HUP EXIT

# Spinner loop
spinner_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spinner_pos=0
max_iterations=3000
iterations=0

while [[ $iterations -lt $max_iterations ]]; do
    printf "\033[s%s\033[u" "${spinner_chars[$spinner_pos]}" >&2
    spinner_pos=$(( (spinner_pos + 1) % 10 ))
    iterations=$((iterations + 1))
    sleep 0.1
done
SPINNER_EOF

    chmod +x "$spinner_script"

    # Start spinner script in background
    "$spinner_script" &
    SPINNER_PID=$!

    # Give it a moment to set up its process group
    sleep 0.05
}

# Stop spinner animation
stop_spinner() {
    if [[ -n "$SPINNER_PID" ]] && [[ "$SPINNER_PID" != "0" ]]; then
        # Check if process exists
        if kill -0 "$SPINNER_PID" 2>/dev/null; then
            # Kill the entire process group (negative PID)
            # This kills the spinner script AND all its children (including sleep)
            kill -- -"$SPINNER_PID" 2>/dev/null || true

            # Also send to the process itself
            kill -TERM "$SPINNER_PID" 2>/dev/null || true

            # Wait briefly for termination (max 1 second)
            local wait_count=0
            while [[ $wait_count -lt 10 ]]; do
                if ! kill -0 "$SPINNER_PID" 2>/dev/null; then
                    break
                fi
                sleep 0.1
                wait_count=$((wait_count + 1))
            done

            # Force kill if still alive
            if kill -0 "$SPINNER_PID" 2>/dev/null; then
                kill -9 "$SPINNER_PID" 2>/dev/null || true
                kill -9 -"$SPINNER_PID" 2>/dev/null || true
            fi

            # Final cleanup: kill any remaining children
            pkill -P "$SPINNER_PID" 2>/dev/null || true
        fi

        # Clean up temporary spinner script
        rm -f "/tmp/.installer-spinner-$$.sh" 2>/dev/null || true

        # Clear spinner character by printing space
        printf "\033[s \033[u" >&2
        SPINNER_PID=""
    fi

    # Show cursor
    printf "\033[?25h" >&2
}

# Clear screen
clear_screen() {
    printf '\033[2J\033[H'
}

# Display ASCII banner with gradient colors
print_banner() {
    # Banner lines array
    local -a lines=(
        "    "
        "   d8P                                                       "
        "d888888P                                                     "
        "  ?88'    88bd88b?88   d8P d8888b  88bd88b  d888b8b   .d888b,"
        "  88P     88P'  \`d88   88 d8b_,dP  88P' ?8bd8P' ?88   ?8b,   "
        "  88b    d88     ?8(  d88 88b     d88   88P88b  ,88b    \`?8b "
        "  \`?8b  d88'     \`?88P'?8b\`?888P'd88'   88b\`?88P'\`88b\`?888P' "
        "                                                              "
        "              d8b                      d8,          "
        "              88P                     \`8P           "
        "             d88                                    "
        "   ?88,.d88b,888  ?88   d8P d888b8b    88b  88bd88b "
        "   \`?88'  ?88?88  d88   88 d8P' ?88    88P  88P' ?8b"
        "     88b  d8P 88b ?8(  d88 88b  ,88b  d88  d88   88P"
        "     888888P'  88b\`?88P'?8b\`?88P'\`88bd88' d88'   88b"
        "     88P'                         )88               "
        "    d88                          ,88P     For Proxmox VE"
        "    ?8P                      \`?8888P                "
        " "
    )

    local total_lines=${#lines[@]}

    # Print each line with gradient color
    local i=0
    for line in "${lines[@]}"; do
        local color
        color=$(gradient_color "$i" "$total_lines")
        printf '%b%s%b\n' "$color" "$line" "$c0"
        i=$((i + 1))
    done
}

# Initialize logging
init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || {
        echo "Warning: Cannot create log file at $LOG_FILE" >&2
        return 1
    }
    log "INFO" "Installer started (version $INSTALLER_VERSION)"
}

# Write to log file
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Info message (blue)
info() {
    printf '%b\n' "${c4}  ${*}${c0}"
    log "INFO" "$*"
}

# Success message (green)
success() {
    printf '%b\n' "${c2}  ${*}${c0}"
    log "SUCCESS" "$*"
}

# Warning message (yellow)
warning() {
    printf '%b\n' "${c3}  ${*}${c0}"
    log "WARNING" "$*"
}

# Error message (red)
error() {
    printf '%b\n' "${c1}  ${*}${c0}" >&2
    log "ERROR" "$*"
}

# Fatal error - print and exit
fatal() {
    error "$*"
    exit $EXIT_ERROR
}

# Print section header
print_header() {
    printf '\n%b\n' "${c6}${c8}${*}${c0}"
    printf '%b\n\n' "${c6}$(printf '%*s' ${#1} '' | tr ' ' '-')${c0}"
}

# ============================================================================
# PRIVILEGE AND DEPENDENCY CHECKS
# ============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This installer must be run as root. Please use: sudo $0"
    fi
    log "INFO" "Root privilege check passed"
}

# Check required dependencies
check_dependencies() {
    local missing_deps=()
    local deps=("perl" "systemctl")

    # Check for wget or curl
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("wget or curl")
    fi

    # Check other dependencies
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing_deps[*]}"
        echo
        info "Please install missing dependencies:"
        echo "  apt-get update && apt-get install -y ${missing_deps[*]}"
        echo
        exit $EXIT_ERROR
    fi

    log "INFO" "All dependencies satisfied"
}

# ============================================================================
# CLUSTER DETECTION
# ============================================================================

# Detect if running on a Proxmox cluster node
is_cluster_node() {
    # Check if /etc/pve directory exists and has cluster configuration
    if [[ -d "/etc/pve/nodes" ]] && [[ $(find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) -gt 1 ]]; then
        return 0
    fi
    return 1
}

# Get cluster node count
get_cluster_node_count() {
    if [[ -d "/etc/pve/nodes" ]]; then
        find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

# Display cluster warning
show_cluster_warning() {
    local node_count
    node_count=$(get_cluster_node_count)

    if [[ "$node_count" -gt 1 ]]; then
        echo
        warning "⚠️  Proxmox Cluster Detected (${node_count} nodes)"
        echo
        info "This installer only updates the current node."
        info "To update all cluster nodes, use the cluster update script:"
        echo
        echo "  wget https://raw.githubusercontent.com/${GITHUB_REPO}/main/tools/update-cluster.sh"
        echo "  chmod +x update-cluster.sh"
        echo "  ./update-cluster.sh node1 node2 node3"
        echo
        return 0
    fi
    return 1
}

# Get current node name from cluster membership
get_current_node_name() {
    if [[ ! -f /etc/pve/.members ]]; then
        echo ""
        return 1
    fi

    # Extract nodename from JSON
    grep -Po '"nodename":\s*"\K[^"]+' /etc/pve/.members 2>/dev/null || echo ""
}

# Get list of all cluster nodes with their IPs
# Returns array of "nodename:ip" strings
get_cluster_nodes() {
    if [[ ! -f /etc/pve/.members ]]; then
        return 1
    fi

    local -a nodes=()
    local content
    content=$(cat /etc/pve/.members 2>/dev/null) || return 1

    # Validate basic JSON structure
    if [[ ! "$content" =~ \{.*nodelist.*\} ]]; then
        log "ERROR" "Invalid or corrupted /etc/pve/.members file - missing nodelist structure"
        return 1
    fi

    # Extract nodelist section and parse each node entry
    # Look for pattern: "nodename": { ... "ip": "x.x.x.x" ... }
    local in_nodelist=false
    local current_node=""

    while IFS= read -r line; do
        # Check if we're in the nodelist section
        if [[ "$line" =~ \"nodelist\" ]]; then
            in_nodelist=true
            continue
        fi

        if [[ "$in_nodelist" == true ]]; then
            # Extract node name from line like: "nodename": {
            # Supports any valid hostname (alphanumeric, dots, hyphens, underscores)
            if [[ "$line" =~ \"([a-zA-Z0-9._-]+)\":[[:space:]]*\{ ]]; then
                current_node="${BASH_REMATCH[1]}"
            fi

            # Extract IP from line like: "ip": "10.15.14.195"
            if [[ -n "$current_node" ]] && [[ "$line" =~ \"ip\":[[:space:]]*\"([0-9.]+)\" ]]; then
                local ip="${BASH_REMATCH[1]}"

                # Validate IP format (basic check for x.x.x.x pattern)
                if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                    # Validate each octet is 0-255
                    local valid=true
                    IFS='.' read -ra octets <<< "$ip"
                    for octet in "${octets[@]}"; do
                        if [[ "$octet" -gt 255 ]]; then
                            valid=false
                            break
                        fi
                    done

                    if [[ "$valid" == true ]]; then
                        nodes+=("${current_node}:${ip}")
                    fi
                fi
                current_node=""
            fi

            # Exit nodelist section when we hit the closing brace for the nodelist object
            # Only exit if we have nodes and we're not in a node sub-object (current_node is empty)
            if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*(,)?[[:space:]]*$ ]]; then
                if [[ ${#nodes[@]} -gt 0 ]] && [[ -z "$current_node" ]]; then
                    break
                fi
            fi
        fi
    done <<< "$content"

    # Output the nodes array
    printf '%s\n' "${nodes[@]}"
    return 0
}

# Get list of remote cluster nodes (excludes current node)
# Returns array of "nodename:ip" strings
get_remote_cluster_nodes() {
    local current_node
    current_node=$(get_current_node_name)

    if [[ -z "$current_node" ]]; then
        return 1
    fi

    local -a all_nodes
    mapfile -t all_nodes < <(get_cluster_nodes)

    local -a remote_nodes=()
    for node in "${all_nodes[@]}"; do
        local name="${node%%:*}"
        if [[ "$name" != "$current_node" ]]; then
            remote_nodes+=("$node")
        fi
    done

    # Output the remote nodes array
    printf '%s\n' "${remote_nodes[@]}"
    return 0
}

# Validate SSH connectivity to a cluster node
# Args: $1 = node IP
# Returns: 0 on success, 1 on failure
validate_ssh_to_node() {
    local node_ip="$1"

    if [[ -z "$node_ip" ]]; then
        return 1
    fi

    # Test SSH with timeout and batch mode (no password prompts)
    if ssh -o ConnectTimeout=5 \
           -o BatchMode=yes \
           -o StrictHostKeyChecking=accept-new \
           "root@${node_ip}" "echo test" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Validate SSH connectivity to all cluster nodes
# Populates arrays: ssh_reachable_nodes, ssh_unreachable_nodes
# Returns: 0 if all nodes reachable, 1 if any unreachable
validate_cluster_ssh() {
    local -a remote_nodes
    mapfile -t remote_nodes < <(get_remote_cluster_nodes)

    if [[ ${#remote_nodes[@]} -eq 0 ]]; then
        info "No remote cluster nodes found"
        return 0
    fi

    info "Validating SSH connectivity to cluster nodes..."
    echo

    ssh_reachable_nodes=()
    ssh_unreachable_nodes=()

    for node_info in "${remote_nodes[@]}"; do
        local node_name="${node_info%%:*}"
        local node_ip="${node_info##*:}"

        printf "  Testing %s (%s)... " "$node_name" "$node_ip"

        if validate_ssh_to_node "$node_ip"; then
            echo "${c3}✓ Reachable${c0}"
            ssh_reachable_nodes+=("$node_info")
        else
            echo "${c5}✗ Unreachable${c0}"
            ssh_unreachable_nodes+=("$node_info")
        fi
    done

    echo

    if [[ ${#ssh_unreachable_nodes[@]} -gt 0 ]]; then
        warning "Some nodes are not reachable via SSH:"
        for node_info in "${ssh_unreachable_nodes[@]}"; do
            local node_name="${node_info%%:*}"
            local node_ip="${node_info##*:}"
            echo "  • $node_name ($node_ip)"
        done
        echo
        info "Ensure passwordless SSH is configured between cluster nodes"
        info "To test manually: ssh root@<node_ip> hostname"
        return 1
    fi

    success "All cluster nodes are reachable via SSH"
    return 0
}

# ============================================================================
# INSTALLATION STATE DETECTION
# ============================================================================

# Get currently installed plugin version
get_installed_version() {
    if [[ ! -f "$PLUGIN_FILE" ]]; then
        echo ""
        return 1
    fi

    # Extract version from plugin file
    local version
    version=$(perl -ne 'print $1 if /VERSION\s*=\s*['\''"]([0-9]+\.[0-9]+\.[0-9]+)/' "$PLUGIN_FILE" 2>/dev/null || echo "")

    if [[ -z "$version" ]]; then
        # Try alternative version extraction
        version=$(perl -ne 'print $1 if /version:\s*([0-9]+\.[0-9]+\.[0-9]+)/' "$PLUGIN_FILE" 2>/dev/null || echo "")
    fi

    echo "$version"
}

# Check if plugin is installed
is_plugin_installed() {
    [[ -f "$PLUGIN_FILE" ]]
}

# Get installation state summary
get_install_state() {
    if is_plugin_installed; then
        local version
        version=$(get_installed_version)
        if [[ -n "$version" ]]; then
            echo "installed:$version"
        else
            echo "installed:unknown"
        fi
    else
        echo "not_installed"
    fi
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Cleanup on error
cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Installation failed with exit code $exit_code"
        log "ERROR" "Installation failed with exit code $exit_code"
    fi
}

# Cleanup all background processes
cleanup_all() {
    # Stop spinner first
    stop_spinner

    # Kill any remaining background jobs
    local jobs_pids
    jobs_pids=$(jobs -p 2>/dev/null || true)
    if [[ -n "$jobs_pids" ]]; then
        # shellcheck disable=SC2086
        kill $jobs_pids 2>/dev/null || true
    fi

    # Extra safety: kill any orphaned sleep 0.1 processes that belong to this script
    # This is a safety net for any edge cases
    pkill -f "sleep 0\.1" 2>/dev/null || true
}

# Set up error trap and cleanup
trap 'cleanup_all; cleanup_on_error' EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

# Show help message
show_help() {
    cat << EOF
TrueNAS Proxmox VE Plugin Installer v${INSTALLER_VERSION}

Usage: $0 [OPTIONS]

OPTIONS:
    --version           Display installer version
    --non-interactive   Run in non-interactive mode with defaults
    --help              Show this help message

EXAMPLES:
    # Interactive installation (default)
    $0

    # Non-interactive installation
    $0 --non-interactive

    # One-liner installation from GitHub (auto-detects non-interactive)
    curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash

    # Or with wget
    wget -qO- https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash

For more information, visit:
https://github.com/${GITHUB_REPO}

EOF
}

# Parse command line arguments
parse_arguments() {
    NON_INTERACTIVE=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                echo "TrueNAS Proxmox VE Plugin Installer v${INSTALLER_VERSION}"
                exit 0
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo
                show_help
                exit $EXIT_ERROR
                ;;
        esac
    done
}

# ============================================================================
# GITHUB API INTEGRATION
# ============================================================================

# Detect which download tool to use
get_download_tool() {
    if command -v curl >/dev/null 2>&1; then
        echo "curl"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget"
    else
        return 1
    fi
}

# Download file using available tool
download_file() {
    local url="$1"
    local output="$2"
    local tool
    tool=$(get_download_tool)

    log "INFO" "Downloading $url to $output using $tool"

    case "$tool" in
        curl)
            curl -fsSL -o "$output" "$url" || return 1
            ;;
        wget)
            wget -q -O "$output" "$url" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Download to stdout
download_stdout() {
    local url="$1"
    local tool
    tool=$(get_download_tool)

    case "$tool" in
        curl)
            curl -fsSL "$url" || return 1
            ;;
        wget)
            wget -q -O - "$url" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Fetch GitHub API data
github_api_call() {
    local endpoint="$1"
    local url="https://api.github.com/repos/${GITHUB_REPO}${endpoint}"

    log "INFO" "GitHub API call: $url"

    local response
    response=$(download_stdout "$url" 2>&1) || {
        log "ERROR" "GitHub API call failed: $url"
        return 1
    }

    # Check for rate limiting - only check message field if response lacks expected success fields
    # GitHub success responses have tag_name, assets, etc. Error responses have message field.
    if ! echo "$response" | grep -q '"tag_name"\|"assets"\|"version"'; then
        # This looks like an error response, check for rate limit message
        if echo "$response" | grep -q '"message"'; then
            local message
            message=$(echo "$response" | grep -Po '"message":\s*"\K[^"]+')
            if [[ "$message" == *"rate limit"* ]]; then
                error "GitHub API rate limit exceeded. Please try again later."
                log "ERROR" "GitHub API rate limit exceeded"
                return 1
            fi
        fi
    fi

    echo "$response"
}

# Get latest release from GitHub
get_latest_release() {
    local release_data
    release_data=$(github_api_call "/releases/latest") || {
        error "Failed to fetch latest release from GitHub"
        info "Please check your internet connection and try again"
        return 1
    }

    echo "$release_data"
}

# Get all releases from GitHub
get_all_releases() {
    local releases_data
    releases_data=$(github_api_call "/releases") || {
        error "Failed to fetch releases from GitHub"
        return 1
    }

    echo "$releases_data"
}

# Extract version from release data
get_release_version() {
    local release_data="$1"
    echo "$release_data" | grep -Po '"tag_name":\s*"\K[^"]+' | sed 's/^v//'
}

# Get download URL for plugin file from release
get_plugin_download_url() {
    local release_data="$1"
    local plugin_url

    # Try to find TrueNASPlugin.pm in assets
    # Use sed to extract assets section more reliably than grep -Pzo
    plugin_url=""

    # Check if the asset exists and extract its download URL
    if echo "$release_data" | grep -q '"name":\s*"TrueNASPlugin\.pm"'; then
        # Found the matching asset, extract the browser_download_url from context
        local context_lines
        context_lines=$(echo "$release_data" | grep -A 10 '"name":\s*"TrueNASPlugin\.pm"')
        plugin_url=$(echo "$context_lines" | grep -Po '"browser_download_url":\s*"\K[^"]+' | head -1)
    fi

    if [[ -z "$plugin_url" || "$plugin_url" == "null" ]]; then
        # Fallback to raw GitHub URL
        local tag_name
        tag_name=$(echo "$release_data" | grep -Po '"tag_name":\s*"\K[^"]+')
        plugin_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${tag_name}/TrueNASPlugin.pm"
    fi

    echo "$plugin_url"
}

# Compare two semantic versions
# Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
compare_versions() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi

    local IFS=.
    local i ver1=($v1) ver2=($v2)

    # Fill empty positions with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done

    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done

    return 0
}

# Check if update is available
check_for_updates() {
    local current_version="$1"
    local latest_release
    latest_release=$(get_latest_release) || return 1

    local latest_version
    latest_version=$(get_release_version "$latest_release")

    log "INFO" "Current version: $current_version, Latest version: $latest_version"

    compare_versions "$current_version" "$latest_version"
    local result=$?

    if [[ $result -eq 2 ]]; then
        # Current version is older
        echo "$latest_version"
        return 0
    else
        # Current version is same or newer
        return 1
    fi
}

# Download plugin file with progress
download_plugin() {
    local url="$1"
    local output="$2"
    local show_progress="${3:-true}"

    if [[ "$show_progress" == "true" ]]; then
        info "Downloading plugin from GitHub..."
    fi

    # Create temporary file
    local temp_file="${output}.tmp"

    if download_file "$url" "$temp_file"; then
        mv "$temp_file" "$output"
        log "INFO" "Plugin downloaded successfully to $output"
        return 0
    else
        rm -f "$temp_file"
        log "ERROR" "Failed to download plugin from $url"
        return 1
    fi
}

# ============================================================================
# BACKUP AND ROLLBACK
# ============================================================================

# Create backup of plugin file
backup_plugin() {
    if [[ ! -f "$PLUGIN_FILE" ]]; then
        log "INFO" "No existing plugin to backup"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local version
    version=$(get_installed_version)
    local backup_file="${BACKUP_DIR}/TrueNASPlugin.pm.backup.${version:-unknown}.${timestamp}"

    cp "$PLUGIN_FILE" "$backup_file" || {
        error "Failed to create backup"
        return 1
    }

    success "Backup created: $backup_file"
    log "INFO" "Backup created: $backup_file"
    return 0
}

# List available backups
list_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 1
    fi

    find "$BACKUP_DIR" -name "TrueNASPlugin.pm.backup.*" -type f | sort -r
}

# Human-readable file size
format_size() {
    local bytes="$1"
    local size

    if [[ "$bytes" -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ "$bytes" -lt $((1024 * 1024)) ]]; then
        size=$((bytes / 1024))
        echo "${size}KB"
    elif [[ "$bytes" -lt $((1024 * 1024 * 1024)) ]]; then
        size=$((bytes / 1024 / 1024))
        echo "${size}MB"
    else
        size=$((bytes / 1024 / 1024 / 1024))
        echo "${size}GB"
    fi
}

# Calculate backup age in days
backup_age_days() {
    local backup_file="$1"
    local file_time
    local current_time
    local age_seconds

    file_time=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
    current_time=$(date +%s)
    age_seconds=$((current_time - file_time))
    echo $((age_seconds / 86400))
}

# Format age in human-readable form
format_age() {
    local days="$1"

    if [[ "$days" -eq 0 ]]; then
        echo "Today"
    elif [[ "$days" -eq 1 ]]; then
        echo "1 day ago"
    elif [[ "$days" -lt 30 ]]; then
        echo "${days} days ago"
    elif [[ "$days" -lt 365 ]]; then
        local months=$((days / 30))
        if [[ "$months" -eq 1 ]]; then
            echo "1 month ago"
        else
            echo "${months} months ago"
        fi
    else
        local years=$((days / 365))
        if [[ "$years" -eq 1 ]]; then
            echo "1 year ago"
        else
            echo "${years} years ago"
        fi
    fi
}

# Scan backups and return statistics
scan_backups() {
    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        echo "0:0:0:0"  # count:total_size:oldest_age:newest_age
        return
    fi

    local count=0
    local total_size=0
    local oldest_age=0
    local newest_age=999999

    while IFS= read -r backup; do
        ((count++))
        local size
        size=$(stat -c %s "$backup" 2>/dev/null || stat -f %z "$backup" 2>/dev/null)
        total_size=$((total_size + size))

        local age
        age=$(backup_age_days "$backup")

        if [[ "$age" -gt "$oldest_age" ]]; then
            oldest_age="$age"
        fi

        if [[ "$age" -lt "$newest_age" ]]; then
            newest_age="$age"
        fi
    done <<< "$backups"

    echo "${count}:${total_size}:${oldest_age}:${newest_age}"
}

# Check if backup cleanup should be offered
should_offer_cleanup() {
    local stats
    stats=$(scan_backups)

    IFS=':' read -r count total_size oldest_age newest_age <<< "$stats"

    # Thresholds (can be customized via env vars)
    local max_backups="${BACKUP_MAX_COUNT:-10}"
    local max_age_days="${BACKUP_MAX_AGE_DAYS:-90}"
    local max_size_mb="${BACKUP_MAX_SIZE_MB:-100}"

    local total_size_mb=$((total_size / 1024 / 1024))

    # Offer cleanup if any threshold is exceeded
    if [[ "$count" -gt "$max_backups" ]] || \
       [[ "$oldest_age" -gt "$max_age_days" ]] || \
       [[ "$total_size_mb" -gt "$max_size_mb" ]]; then
        return 0
    fi

    return 1
}

# ============================================================================
# PLUGIN INSTALLATION
# ============================================================================

# Validate plugin syntax
validate_plugin() {
    local plugin_file="$1"

    info "Validating plugin syntax..."
    if perl -c "$plugin_file" >/dev/null 2>&1; then
        success "Plugin syntax is valid"
        return 0
    else
        error "Plugin syntax validation failed"
        perl -c "$plugin_file" 2>&1 | head -10
        return 1
    fi
}

# Install plugin file
install_plugin_file() {
    local source="$1"
    local backup="${2:-true}"

    # Create backup if requested and file exists
    if [[ "$backup" == "true" ]]; then
        backup_plugin || {
            error "Backup failed. Installation aborted for safety."
            return 1
        }
    fi

    # Validate plugin before installation
    if ! validate_plugin "$source"; then
        error "Plugin validation failed. Installation aborted."
        return 1
    fi

    # Ensure target directory exists
    local plugin_dir
    plugin_dir="$(dirname "$PLUGIN_FILE")"
    if [[ ! -d "$plugin_dir" ]]; then
        info "Creating plugin directory $plugin_dir..."
        mkdir -p "$plugin_dir" || {
            error "Failed to create plugin directory"
            return 1
        }
    fi

    # Install plugin
    info "Installing plugin to $PLUGIN_FILE..."
    cp "$source" "$PLUGIN_FILE" || {
        error "Failed to copy plugin file"
        return 1
    }

    # Set correct permissions
    chown root:root "$PLUGIN_FILE"
    chmod 644 "$PLUGIN_FILE"

    success "Plugin installed successfully"
    log "INFO" "Plugin installed to $PLUGIN_FILE"
    return 0
}

# Restart PVE services
restart_pve_services() {
    info "Restarting Proxmox services..."

    local services=("pvedaemon" "pveproxy")
    local failed=false

    for service in "${services[@]}"; do
        if systemctl restart "$service" 2>/dev/null; then
            success "Restarted $service"
        else
            error "Failed to restart $service"
            failed=true
        fi
    done

    if [[ "$failed" == "true" ]]; then
        warning "Some services failed to restart. Please check manually."
        return 1
    fi

    # Wait a moment and verify services are running
    sleep 2
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            success "$service is running"
        else
            error "$service is not running"
            failed=true
        fi
    done

    if [[ "$failed" == "true" ]]; then
        return 1
    fi

    success "All Proxmox services restarted successfully"
    return 0
}

# Install plugin on a remote cluster node
# Args: $1 = node IP, $2 = local plugin file path, $3 = version string (for backup naming)
# Returns: 0 on success, 1 on failure, 2 on success with service restart failure
install_plugin_on_remote_node() {
    local node_ip="$1"
    local plugin_file="$2"
    local version="$3"

    if [[ -z "$node_ip" || ! -f "$plugin_file" ]]; then
        log "ERROR" "Remote installation: Invalid parameters (ip=$node_ip, file=$plugin_file)"
        return 1
    fi

    local temp_remote="/tmp/TrueNASPlugin.pm.$$"
    log "INFO" "Starting remote installation to $node_ip (version $version)"

    # Transfer plugin file to remote node
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${node_ip}" \
        "cat > ${temp_remote}" < "$plugin_file" 2>/dev/null; then
        log "ERROR" "Remote installation to $node_ip: SSH transfer failed"
        echo "SSH transfer failed"
        return 1
    fi
    log "INFO" "Remote installation to $node_ip: File transferred successfully"

    # Validate plugin syntax on remote node
    if ! ssh "root@${node_ip}" "perl -c ${temp_remote}" >/dev/null 2>&1; then
        ssh "root@${node_ip}" "rm -f ${temp_remote}" 2>/dev/null
        log "ERROR" "Remote installation to $node_ip: Syntax validation failed"
        echo "Syntax validation failed"
        return 1
    fi
    log "INFO" "Remote installation to $node_ip: Syntax validation passed"

    # Create backup directory on remote if it doesn't exist
    ssh "root@${node_ip}" "mkdir -p ${BACKUP_DIR}" 2>/dev/null

    # Create backup on remote node (if plugin exists) using remote timestamp
    local backup_result
    backup_result=$(ssh "root@${node_ip}" "
        if [[ -f ${PLUGIN_FILE} ]]; then
            remote_ts=\$(date +%Y%m%d_%H%M%S)
            if cp ${PLUGIN_FILE} ${BACKUP_DIR}/TrueNASPlugin.pm.backup.${version}.\${remote_ts} 2>&1; then
                echo 'success'
            else
                echo 'failed'
            fi
        else
            echo 'no-plugin'
        fi
    " 2>&1)

    if [[ "$backup_result" == "failed" ]]; then
        log "WARNING" "Remote installation to $node_ip: Backup creation failed (proceeding anyway)"
        echo "Backup creation failed (proceeding anyway)" >&2
    elif [[ "$backup_result" == "success" ]]; then
        log "INFO" "Remote installation to $node_ip: Backup created successfully"
    fi

    # Install plugin on remote node atomically with error handling
    if ! ssh "root@${node_ip}" "
        set -e
        mkdir -p \$(dirname ${PLUGIN_FILE})
        cp ${temp_remote} ${PLUGIN_FILE}
        chown root:root ${PLUGIN_FILE}
        chmod 644 ${PLUGIN_FILE}
        rm -f ${temp_remote}
    " 2>&1; then
        # Clean up temp file on failure
        ssh "root@${node_ip}" "rm -f ${temp_remote}" 2>/dev/null || true
        log "ERROR" "Remote installation to $node_ip: Installation failed"
        echo "Installation failed"
        return 1
    fi
    log "INFO" "Remote installation to $node_ip: Plugin installed successfully"

    # Restart services on remote node
    if ! ssh "root@${node_ip}" "systemctl restart pvedaemon pveproxy" 2>/dev/null; then
        log "WARNING" "Remote installation to $node_ip: Service restart failed"
        echo "Service restart failed - manual restart required"
        return 2  # Special return code: installed but needs manual service restart
    fi
    log "INFO" "Remote installation to $node_ip: Services restarted successfully"

    return 0
}

# Display cluster installation summary
# Args: arrays successful_nodes, failed_nodes, failure_reasons
show_cluster_install_summary() {
    local total=$((${#successful_nodes[@]} + ${#failed_nodes[@]}))

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${#successful_nodes[@]} -gt 0 ]]; then
        success "Successfully updated ${#successful_nodes[@]} of $total nodes:"
        for node in "${successful_nodes[@]}"; do
            echo "  ${c3}✓${c0} $node"
        done
    fi

    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        echo
        warning "Failed to update ${#failed_nodes[@]} nodes:"
        for i in "${!failed_nodes[@]}"; do
            echo "  ${c5}✗${c0} ${failed_nodes[$i]}: ${failure_reasons[$i]}"
        done
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Perform cluster-wide installation
# Args: $1 = version (e.g., "latest" or "1.0.7")
# Returns: 0 if any nodes succeeded, 1 if all failed
perform_cluster_wide_installation() {
    local version="${1:-latest}"
    local include_local="${2:-true}"

    print_header "Installing TrueNAS Plugin (Cluster-Wide)"

    # Check for non-interactive mode
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        error "Cluster-wide installation requires interactive mode"
        info "In non-interactive mode, the installer only updates the local node"
        return 1
    fi

    # Validate cluster and SSH connectivity
    if ! is_cluster_node; then
        error "This is not a cluster node"
        info "Cluster-wide installation is only available for clustered nodes"
        return 1
    fi

    # Get remote nodes
    local -a remote_nodes
    mapfile -t remote_nodes < <(get_remote_cluster_nodes)

    if [[ ${#remote_nodes[@]} -eq 0 ]]; then
        warning "No remote cluster nodes found"
        info "Falling back to local installation only"
        perform_installation "$version"
        return $?
    fi

    # Show cluster information
    local current_node
    current_node=$(get_current_node_name)
    info "Current node: $current_node"
    info "Remote nodes: ${#remote_nodes[@]}"
    for node_info in "${remote_nodes[@]}"; do
        local node_name="${node_info%%:*}"
        local node_ip="${node_info##*:}"
        echo "  • $node_name ($node_ip)"
    done
    echo

    # Validate SSH connectivity
    declare -a ssh_reachable_nodes
    declare -a ssh_unreachable_nodes

    if ! validate_cluster_ssh; then
        echo
        read -rp "Continue with only reachable nodes? (y/N): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy] ]]; then
            info "Cluster installation cancelled"
            return 1
        fi
        # Update remote_nodes to only include reachable ones
        remote_nodes=("${ssh_reachable_nodes[@]}")
    fi

    # Confirmation prompt before proceeding
    echo
    warning "This will install/update the TrueNAS plugin on all cluster nodes"
    info "Total nodes to update: $((${#remote_nodes[@]} + 1)) (1 local + ${#remote_nodes[@]} remote)"
    echo
    read -rp "Do you want to proceed? (y/N): " confirm_choice
    if [[ ! "$confirm_choice" =~ ^[Yy] ]]; then
        info "Cluster installation cancelled"
        return 1
    fi

    # Download plugin from GitHub
    info "Fetching release from GitHub..."
    local release_data
    if [[ "$version" == "latest" ]]; then
        release_data=$(get_latest_release) || return 1
    else
        release_data=$(github_api_call "/releases/tags/v${version}") || {
            error "Version $version not found"
            return 1
        }
    fi

    local install_version
    install_version=$(get_release_version "$release_data")
    info "Installing version: $install_version"

    local download_url
    download_url=$(get_plugin_download_url "$release_data")

    local temp_file="/tmp/TrueNASPlugin.pm.$$"
    if ! download_plugin "$download_url" "$temp_file"; then
        error "Failed to download plugin"
        rm -f "$temp_file"
        return 1
    fi

    # Install on local node first if requested
    if [[ "$include_local" == "true" ]]; then
        echo
        info "Installing on local node ($current_node)..."

        if install_plugin_file "$temp_file"; then
            if restart_pve_services; then
                success "Local node installation completed"
            else
                warning "Local node installed but services may need manual restart"
            fi
        else
            error "Local node installation failed"
            rm -f "$temp_file"
            return 1
        fi
    fi

    # Install on remote nodes
    echo
    info "Installing on remote cluster nodes..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    declare -a successful_nodes=()
    declare -a failed_nodes=()
    declare -a failure_reasons=()

    local total_nodes=${#remote_nodes[@]}
    local current=0

    for node_info in "${remote_nodes[@]}"; do
        ((current++))
        local node_name="${node_info%%:*}"
        local node_ip="${node_info##*:}"

        printf "[%d/%d] %s (%s): " "$current" "$total_nodes" "$node_name" "$node_ip"

        local error_msg
        error_msg=$(install_plugin_on_remote_node "$node_ip" "$temp_file" "$install_version" 2>&1)
        local result=$?

        if [[ $result -eq 0 ]]; then
            echo "${c3}✓ Success${c0}"
            successful_nodes+=("$node_name")
        elif [[ $result -eq 2 ]]; then
            echo "${c4}⚠ Success (restart needed)${c0}"
            successful_nodes+=("$node_name (services need restart)")
        else
            echo "${c5}✗ Failed${c0}"
            failed_nodes+=("$node_name")
            failure_reasons+=("${error_msg:-Unknown error}")
        fi
    done

    rm -f "$temp_file"

    # Show summary
    show_cluster_install_summary

    # Offer retry for failed nodes
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        echo
        read -rp "Retry failed nodes? (y/N): " retry_choice
        if [[ "$retry_choice" =~ ^[Yy] ]]; then
            info "Waiting 5 seconds before retry..."
            sleep 5

            # Download plugin again for retry
            local retry_temp="/tmp/TrueNASPlugin.pm.retry.$$"
            if download_plugin "$download_url" "$retry_temp"; then
                echo
                info "Retrying failed nodes..."
                echo

                declare -a retry_successful=()
                declare -a retry_failed=()
                declare -a retry_reasons=()

                for i in "${!failed_nodes[@]}"; do
                    local node_name="${failed_nodes[$i]}"

                    # Find node IP from original list
                    local node_ip=""
                    for node_info in "${remote_nodes[@]}"; do
                        if [[ "${node_info%%:*}" == "$node_name" ]]; then
                            node_ip="${node_info##*:}"
                            break
                        fi
                    done

                    if [[ -z "$node_ip" ]]; then
                        continue
                    fi

                    printf "  %s (%s): " "$node_name" "$node_ip"

                    local retry_error
                    retry_error=$(install_plugin_on_remote_node "$node_ip" "$retry_temp" "$install_version" 2>&1)
                    local retry_result=$?

                    if [[ $retry_result -eq 0 ]]; then
                        echo "${c3}✓ Success${c0}"
                        retry_successful+=("$node_name")
                        # Move from failed to successful
                        successful_nodes+=("$node_name")
                    elif [[ $retry_result -eq 2 ]]; then
                        echo "${c4}⚠ Success (restart needed)${c0}"
                        retry_successful+=("$node_name (services need restart)")
                        successful_nodes+=("$node_name (services need restart)")
                    else
                        echo "${c5}✗ Failed${c0}"
                        retry_failed+=("$node_name")
                        retry_reasons+=("${retry_error:-Unknown error}")
                    fi
                done

                rm -f "$retry_temp"

                # Update failed lists
                failed_nodes=("${retry_failed[@]}")
                failure_reasons=("${retry_reasons[@]}")

                # Show updated summary
                show_cluster_install_summary
            fi
        fi
    fi

    echo

    if [[ ${#successful_nodes[@]} -gt 0 ]]; then
        success "Cluster-wide installation completed"

        if [[ "$include_local" == "true" ]]; then
            show_next_steps
        fi

        return 0
    else
        error "All cluster nodes failed to update"
        return 1
    fi
}

# Full installation workflow
perform_installation() {
    local version="${1:-latest}"

    print_header "Installing TrueNAS Plugin"

    # Get release information
    local release_data
    if [[ "$version" == "latest" ]]; then
        info "Fetching latest release from GitHub..."
        release_data=$(get_latest_release) || return 1
    else
        info "Fetching release $version from GitHub..."
        release_data=$(github_api_call "/releases/tags/v${version}") || {
            error "Version $version not found"
            return 1
        }
    fi

    local install_version
    install_version=$(get_release_version "$release_data")
    info "Installing version: $install_version"

    # Get download URL
    local download_url
    download_url=$(get_plugin_download_url "$release_data")
    info "Download URL: $download_url"

    # Download to temporary location
    local temp_file="/tmp/TrueNASPlugin.pm.$$"
    if ! download_plugin "$download_url" "$temp_file"; then
        error "Failed to download plugin"
        rm -f "$temp_file"
        return 1
    fi

    # Install the plugin
    if ! install_plugin_file "$temp_file"; then
        error "Installation failed"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"

    # Restart services
    if ! restart_pve_services; then
        warning "Plugin installed but services may need manual restart"
    fi

    echo
    success "TrueNAS Plugin v${install_version} installed successfully!"

    # Show cluster warning if applicable
    if is_cluster_node; then
        show_cluster_warning
    fi

    # Show next steps
    show_next_steps

    return 0
}

# Display next steps and helpful information
show_next_steps() {
    echo
    info "Next steps:"
    echo "  1. Configure TrueNAS storage (if not done yet)"
    echo "  2. Run health check to verify connectivity"
    echo "  3. Create test VM to validate storage"
    echo
    info "Useful commands:"
    echo "  • Check storage status:    pvesm status"
    echo "  • List TrueNAS storage:    pvesm list <storage-name>"
    echo "  • Check iSCSI sessions:    iscsiadm -m session"
    echo
    info "Documentation:"
    echo "  • GitHub: https://github.com/${GITHUB_REPO}"
    echo "  • Wiki: https://github.com/${GITHUB_REPO}/wiki"
    echo
    info "Example: Create a test VM"
    echo "  qm create 999 --name test-vm --memory 2048 --net0 virtio,bridge=vmbr0"
    echo "  qm set 999 --scsi0 <storage-name>:10"
    echo "  qm start 999"
    echo
}

# ============================================================================
# INTERACTIVE MENU SYSTEM
# ============================================================================

# Display menu and get user choice
show_menu() {
    local title="$1"
    shift
    local options=("$@")

    printf '\n%b\n' "${c6}${c8}${title}${c0}"
    printf '%b\n\n' "${c6}$(printf '%*s' ${#title} '' | tr ' ' '-')${c0}"

    local i=1
    for option in "${options[@]}"; do
        printf '  %b%s%b %s\n' "${c6}" "$i)" "${c0}" "$option"
        ((i++))
    done
    printf '  %b%s%b %s\n\n' "${c3}" "0)" "${c0}" "Exit"
}

# Read user menu choice
read_choice() {
    local max="$1"
    local choice

    while true; do
        read -rp "Enter choice [0-${max}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 0 ]] && [[ "$choice" -le "$max" ]]; then
            echo "$choice"
            return 0
        else
            error "Invalid choice. Please enter a number between 0 and $max"
        fi
    done
}

# Main menu for when plugin is not installed
menu_not_installed() {
    while true; do
        # Clear screen and show banner
        clear_screen
        print_banner

        # Check if backups exist
        local backups
        backups=$(list_backups 2>/dev/null | wc -l || echo "0")
        local has_backups=false
        if [[ "$backups" -gt 0 ]]; then
            has_backups=true
        fi

        # Build menu options dynamically
        local menu_options=("Install latest version" "Install specific version" "View available versions")
        local max_choice=3

        # Add cluster-wide option if in a cluster
        local cluster_option_position=0
        if is_cluster_node; then
            menu_options+=("Install latest version (all cluster nodes)")
            max_choice=4
            cluster_option_position=4
        fi

        if [[ "$has_backups" = true ]]; then
            menu_options+=("Restore from backup ($backups available)")
            max_choice=$((max_choice + 1))
        fi

        # Check if backup cleanup should be offered
        local should_manage_backups=false
        if should_offer_cleanup; then
            should_manage_backups=true
            menu_options+=("Manage backups")
            max_choice=$((max_choice + 1))
        fi

        show_menu "TrueNAS Plugin - Not Installed" "${menu_options[@]}"

        local choice
        choice=$(read_choice "$max_choice")

        case $choice in
            0)
                info "Exiting installer"
                exit $EXIT_SUCCESS
                ;;
            1)
                if perform_installation "latest"; then
                    # Prompt to configure storage after successful installation
                    if [[ "$NON_INTERACTIVE" != "true" ]]; then
                        echo
                        read -rp "Would you like to configure storage now? (y/N): " response
                        if [[ "$response" =~ ^[Yy] ]]; then
                            menu_configure_storage
                            # Offer health check after configuration
                            echo
                            read -rp "Would you like to run a health check now? (y/N): " hc_response
                            if [[ "$hc_response" =~ ^[Yy] ]]; then
                                echo
                                menu_health_check
                            fi
                        fi
                    fi
                    read -rp "Press Enter to return to main menu..."
                    # After successful installation, break out to re-detect state
                    return 0
                else
                    read -rp "Press Enter to return to main menu..."
                fi
                ;;
            2)
                if menu_install_specific_version; then
                    # After successful installation, break out to re-detect state
                    return 0
                fi
                read -rp "Press Enter to return to main menu..."
                ;;
            3)
                menu_view_versions
                ;;
            4)
                # Check if this is cluster-wide option or backup/manage option
                if [[ "$cluster_option_position" -eq 4 ]]; then
                    # Cluster-wide installation
                    if perform_cluster_wide_installation "latest"; then
                        read -rp "Press Enter to return to main menu..."
                        return 0
                    else
                        read -rp "Press Enter to return to main menu..."
                    fi
                elif [[ "$has_backups" = true ]]; then
                    menu_rollback
                elif [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    error "Invalid choice"
                fi
                ;;
            5)
                if [[ "$has_backups" = true ]]; then
                    menu_rollback
                elif [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    error "Invalid choice"
                fi
                ;;
            6)
                if [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    error "Invalid choice"
                fi
                ;;
        esac
    done
}

# Main menu for when plugin is installed
menu_installed() {
    local current_version="$1"

    while true; do
        # Clear screen and show banner
        clear_screen
        print_banner

        # Check for updates
        local update_notice=""
        local latest_version
        if latest_version=$(check_for_updates "$current_version" 2>/dev/null); then
            update_notice=" (Update available: v${latest_version})"
        fi

        # Check if backup cleanup should be offered
        local should_manage_backups=false
        if should_offer_cleanup; then
            should_manage_backups=true
        fi

        # Build menu dynamically
        local -a menu_items=("Update to latest version")
        local max_choice=1

        # Add cluster-wide update option if in a cluster
        local cluster_option_position=0
        if is_cluster_node; then
            menu_items+=("Update all cluster nodes")
            max_choice=2
            cluster_option_position=2
        fi

        menu_items+=("Install specific version" "Configure storage" "Run health check" "View available versions" "Rollback to backup")
        max_choice=$((max_choice + 5))

        if [[ "$should_manage_backups" = true ]]; then
            menu_items+=("Manage backups")
            max_choice=$((max_choice + 1))
        fi

        menu_items+=("Uninstall plugin")
        max_choice=$((max_choice + 1))

        show_menu "TrueNAS Plugin v${current_version} - Installed${update_notice}" "${menu_items[@]}"

        local choice
        choice=$(read_choice "$max_choice")

        case $choice in
            0)
                info "Exiting installer"
                exit $EXIT_SUCCESS
                ;;
            1)
                # Update to latest version (local only)
                if perform_installation "latest"; then
                    # Offer to run health check after successful update
                    if [[ "$NON_INTERACTIVE" != "true" ]]; then
                        echo
                        read -rp "Would you like to run a health check now? (y/N): " response
                        if [[ "$response" =~ ^[Yy] ]]; then
                            echo
                            menu_health_check
                        fi
                    fi
                fi
                read -rp "Press Enter to return to main menu..."
                ;;
            2)
                # This could be cluster-wide update OR install specific version
                if [[ "$cluster_option_position" -eq 2 ]]; then
                    # Cluster-wide update
                    if perform_cluster_wide_installation "latest"; then
                        read -rp "Press Enter to return to main menu..."
                    else
                        read -rp "Press Enter to return to main menu..."
                    fi
                else
                    # Install specific version
                    menu_install_specific_version
                    read -rp "Press Enter to return to main menu..."
                fi
                ;;
            3)
                # Install specific version
                menu_install_specific_version
                read -rp "Press Enter to return to main menu..."
                ;;
            4)
                # Configure storage
                menu_configure_storage
                ;;
            5)
                # Run health check
                menu_health_check
                ;;
            6)
                # View available versions
                menu_view_versions
                ;;
            7)
                # Rollback to backup
                menu_rollback
                ;;
            8)
                # Manage backups OR Uninstall (depends on should_manage_backups)
                if [[ "$should_manage_backups" = true ]]; then
                    menu_manage_backups
                else
                    menu_uninstall
                    read -rp "Press Enter to return to main menu..."
                    return 0
                fi
                ;;
            9)
                # Uninstall plugin (when manage backups is also present)
                menu_uninstall
                read -rp "Press Enter to return to main menu..."
                return 0
                ;;
        esac
    done
}

# Menu: View available versions
menu_view_versions() {
    print_header "Available Versions"

    info "Fetching releases from GitHub..."
    local releases
    releases=$(get_all_releases) || {
        error "Failed to fetch releases"
        read -rp "Press Enter to continue..."
        return 1
    }

    echo
    echo "$releases" | grep -Po '"tag_name":\s*"\K[^"]+' | head -20 | while IFS= read -r tag; do
        # Extract corresponding name and date for this release
        # Use grep -F for literal string matching and -A 10 to capture published_at field
        release_block=$(echo "$releases" | grep -A 10 -F "\"tag_name\": \"$tag\"" || echo "")
        name=$(echo "$release_block" | grep -Po '"name":\s*"\K[^"]+' | head -1 || echo "Release")
        date=$(echo "$release_block" | grep -Po '"published_at":\s*"\K[^T]+' | head -1 || echo "Unknown date")
        version="${tag#v}"
        echo "  • v$version - $name ($date)"
    done
    echo

    if [[ $(echo "$releases" | grep -o '"tag_name"' | wc -l) -gt 20 ]]; then
        info "Showing latest 20 releases. Visit GitHub for full list."
    fi

    read -rp "Press Enter to continue..."
}

# Menu: Run health check
menu_health_check() {
    print_header "TrueNAS Plugin Health Check"

    # List available TrueNAS storage
    info "Detecting TrueNAS storage configurations..."
    echo

    if [[ ! -f "$STORAGE_CFG" ]]; then
        warning "No storage.cfg found - please configure storage first"
        read -rp "Press Enter to continue..."
        return 1
    fi

    local storages
    storages=$(grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}')

    if [[ -z "$storages" ]]; then
        warning "No TrueNAS storage configured"
        info "Please configure storage first from the main menu"
        read -rp "Press Enter to continue..."
        return 1
    fi

    # Show available storage
    info "Available TrueNAS storage:"
    echo "$storages" | while read -r storage; do
        echo "  • $storage"
    done
    echo

    # Prompt for storage name
    local storage_name
    read -rp "Enter storage name to check (or press Enter for first): " storage_name

    if [[ -z "$storage_name" ]]; then
        storage_name=$(echo "$storages" | head -1)
        info "Using: $storage_name"
    fi

    # Verify storage exists
    if ! echo "$storages" | grep -q "^${storage_name}$"; then
        error "Storage '$storage_name' not found"
        read -rp "Press Enter to continue..."
        return 1
    fi

    echo
    info "Running health check on storage: $storage_name"
    echo

    # Run health check and capture exit code
    # Don't let non-zero returns trigger error trap
    run_health_check "$storage_name" || true

    echo
    read -rp "Press Enter to continue..."
}

# Extract storage configuration block safely
get_storage_config_value() {
    local storage_name="$1"
    local param_name="$2"
    local config_block

    # Extract only the configuration block for this storage (stop at next storage entry)
    config_block=$(awk "/^truenasplugin: ${storage_name}\$/{flag=1; next} /^truenasplugin:/{flag=0} flag" "$STORAGE_CFG")

    # Extract parameter from block
    echo "$config_block" | grep "^\s*${param_name}" | awk '{print $2}' | head -1
}

# Perform health check on a storage
run_health_check() {
    local storage_name="$1"
    local warnings=0
    local errors=0
    local checks_passed=0
    local checks_total=0
    local checks_skipped=0

    # Helper function for check output
    check_result() {
        local name="$1"
        local status="$2"
        local message="$3"

        printf "%-30s " "${name}:"
        case "$status" in
            OK)
                echo -e "${COLOR_GREEN}✓${COLOR_RESET} $message"
                ((checks_passed++))
                ((checks_total++))
                ;;
            WARNING)
                echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $message"
                ((warnings++))
                ((checks_total++))
                ;;
            CRITICAL)
                echo -e "${COLOR_RED}✗${COLOR_RESET} $message"
                ((errors++))
                ((checks_total++))
                ;;
            SKIP)
                echo -e "${COLOR_CYAN}-${COLOR_RESET} $message"
                ((checks_skipped++))
                ;;
        esac
    }

    # Check 1: Plugin file installed
    if [[ -f "$PLUGIN_FILE" ]]; then
        local version
        version=$(grep 'our $VERSION' "$PLUGIN_FILE" 2>/dev/null | grep -oP "[0-9.]+" || echo "unknown")
        check_result "Plugin file" "OK" "Installed v$version"
    else
        check_result "Plugin file" "CRITICAL" "Not installed"
    fi

    # Check 2: Storage configured
    if grep -q "^truenasplugin: ${storage_name}$" "$STORAGE_CFG" 2>/dev/null; then
        check_result "Storage configuration" "OK" "Configured"
    else
        check_result "Storage configuration" "CRITICAL" "Not configured"
        echo
        error "Storage '$storage_name' not found in configuration"
        return 2
    fi

    # Check 3: Storage status
    printf "%-30s " "Storage status:"
    start_spinner
    local space_result
    if pvesm status 2>/dev/null | grep -q "$storage_name.*active"; then
        local total_kb used_kb percent
        read -r total_kb used_kb percent < <(pvesm status 2>/dev/null | grep "$storage_name" | awk '{print $4, $5, $7}')
        # Convert KB to GB
        local used_gb=$(awk "BEGIN {printf \"%.2f\", $used_kb/1024/1024}")
        local total_gb=$(awk "BEGIN {printf \"%.2f\", $total_kb/1024/1024}")
        space_result="${COLOR_GREEN}✓${COLOR_RESET} Active (${used_gb}GB / ${total_gb}GB used, ${percent})"
        ((checks_passed++))
    else
        space_result="${COLOR_YELLOW}⚠${COLOR_RESET} Inactive or not accessible"
        ((warnings++))
    fi
    stop_spinner
    echo -e "\r$(printf "%-30s " "Storage status:")${space_result}"
    ((checks_total++))

    # Check 4: Content type
    local content
    content=$(get_storage_config_value "$storage_name" "content")
    if [[ "$content" == "images" ]]; then
        check_result "Content type" "OK" "images"
    elif [[ -n "$content" ]]; then
        check_result "Content type" "WARNING" "$content (should be 'images')"
    else
        check_result "Content type" "WARNING" "Not configured"
    fi

    # Check 5: TrueNAS API reachability
    local api_host
    api_host=$(get_storage_config_value "$storage_name" "api_host")
    local api_port
    api_port=$(get_storage_config_value "$storage_name" "api_port")
    api_port=${api_port:-443}

    if [[ -n "$api_host" ]]; then
        printf "%-30s " "TrueNAS API:"
        start_spinner
        local api_result
        if timeout 5 bash -c ">/dev/tcp/$api_host/$api_port" 2>/dev/null; then
            api_result="${COLOR_GREEN}✓${COLOR_RESET} Reachable on $api_host:$api_port"
            ((checks_passed++))
        else
            api_result="${COLOR_RED}✗${COLOR_RESET} Cannot reach $api_host:$api_port"
            ((errors++))
        fi
        stop_spinner
        echo -e "\r$(printf "%-30s " "TrueNAS API:")${api_result}"
        ((checks_total++))
    else
        check_result "TrueNAS API" "CRITICAL" "API host not configured"
    fi

    # Check 6: Dataset configuration
    local dataset
    dataset=$(get_storage_config_value "$storage_name" "dataset")
    if [[ -n "$dataset" ]]; then
        check_result "Dataset" "OK" "$dataset"
    else
        check_result "Dataset" "CRITICAL" "Not configured"
    fi

    # Detect transport mode
    local transport_mode
    transport_mode=$(get_storage_config_value "$storage_name" "transport_mode")
    transport_mode=${transport_mode:-iscsi}  # Default to iscsi if not specified

    # Check 7: Transport-specific target/subsystem configuration
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # Check for nvme-cli
        if check_nvme_cli; then
            check_result "nvme-cli" "OK" "Installed"
        else
            check_result "nvme-cli" "CRITICAL" "Not installed (required for NVMe/TCP)"
        fi

        # Check subsystem NQN
        local subsystem_nqn
        subsystem_nqn=$(get_storage_config_value "$storage_name" "subsystem_nqn")
        if [[ -n "$subsystem_nqn" ]]; then
            check_result "Subsystem NQN" "OK" "$subsystem_nqn"
        else
            check_result "Subsystem NQN" "CRITICAL" "Not configured"
        fi

        # Check host NQN
        local hostnqn
        hostnqn=$(get_storage_config_value "$storage_name" "hostnqn")
        if [[ -n "$hostnqn" ]]; then
            check_result "Host NQN" "OK" "$hostnqn"
        elif [[ -f /etc/nvme/hostnqn ]]; then
            local system_hostnqn
            system_hostnqn=$(cat /etc/nvme/hostnqn 2>/dev/null | tr -d '\n')
            check_result "Host NQN" "OK" "Using system: $system_hostnqn"
        else
            check_result "Host NQN" "WARNING" "Not configured (will use system default)"
        fi
    else
        # iSCSI mode - check target IQN
        local target_iqn
        target_iqn=$(get_storage_config_value "$storage_name" "target_iqn")
        if [[ -n "$target_iqn" ]]; then
            check_result "Target IQN" "OK" "$target_iqn"
        else
            check_result "Target IQN" "CRITICAL" "Not configured"
        fi
    fi

    # Check 8: Discovery portal
    local discovery_portal
    discovery_portal=$(get_storage_config_value "$storage_name" "discovery_portal")
    if [[ -n "$discovery_portal" ]]; then
        check_result "Discovery portal" "OK" "$discovery_portal"
    else
        check_result "Discovery portal" "CRITICAL" "Not configured"
    fi

    # Check 9: Sessions/Connections (transport-specific)
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        if [[ -n "$subsystem_nqn" ]]; then
            printf "%-30s " "NVMe connections:"
            start_spinner
            local nvme_result
            if check_nvme_cli && nvme list-subsys 2>/dev/null | grep -q "$subsystem_nqn"; then
                local path_count live_count
                path_count=$(nvme list-subsys 2>/dev/null | grep -A50 "$subsystem_nqn" | grep -c "transport: tcp" || echo "0")
                live_count=$(nvme list-subsys 2>/dev/null | grep -A50 "$subsystem_nqn" | grep -c "state: live" || echo "0")
                nvme_result="${COLOR_GREEN}✓${COLOR_RESET} Connected (${path_count} path(s), ${live_count} live)"
                ((checks_passed++))
            else
                nvme_result="${COLOR_YELLOW}⚠${COLOR_RESET} Not connected"
                ((warnings++))
            fi
            stop_spinner
            echo -e "\r\033[K$(printf "%-30s " "NVMe connections:")${nvme_result}"
            ((checks_total++))
        else
            check_result "NVMe connections" "SKIP" "Cannot check (no subsystem NQN)"
        fi
    else
        # iSCSI sessions check
        if [[ -n "$target_iqn" ]]; then
            printf "%-30s " "iSCSI sessions:"
            start_spinner
            local session_count
            session_count=$(iscsiadm -m session 2>/dev/null | grep -c "$target_iqn" || echo "0")
            local iscsi_result
            if [[ "$session_count" -gt 0 ]]; then
                iscsi_result="${COLOR_GREEN}✓${COLOR_RESET} $session_count active session(s)"
                ((checks_passed++))
            else
                iscsi_result="${COLOR_YELLOW}⚠${COLOR_RESET} No active sessions"
                ((warnings++))
            fi
            stop_spinner
            echo -e "\r$(printf "%-30s " "iSCSI sessions:")${iscsi_result}"
            ((checks_total++))
        else
            check_result "iSCSI sessions" "SKIP" "Cannot check (no target IQN)"
        fi
    fi

    # Check 10: Multipath configuration (transport-specific)
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        # Check native NVMe multipath
        local portals
        portals=$(get_storage_config_value "$storage_name" "portals")
        if [[ -n "$portals" ]]; then
            ((checks_total++))
            if [[ -f /sys/module/nvme_core/parameters/multipath ]]; then
                local nvme_mp
                nvme_mp=$(cat /sys/module/nvme_core/parameters/multipath 2>/dev/null)
                if [[ "$nvme_mp" == "Y" ]]; then
                    check_result "Native multipath" "OK" "Enabled (kernel)"
                else
                    check_result "Native multipath" "WARNING" "Disabled in kernel"
                fi
            else
                check_result "Native multipath" "WARNING" "Cannot detect (nvme_core not loaded)"
            fi
        else
            check_result "Native multipath" "SKIP" "No additional portals configured"
        fi
    else
        # iSCSI multipath check
        local use_multipath
        use_multipath=$(get_storage_config_value "$storage_name" "use_multipath")
        if [[ "$use_multipath" == "1" ]]; then
            ((checks_total++))
            if command -v multipath &> /dev/null; then
                local mpath_count
                mpath_count=$(multipath -ll 2>/dev/null | grep -c "dm-" 2>/dev/null || echo "0")
                mpath_count=$(echo "$mpath_count" | head -1 | tr -d '\n ')
                if [[ "$mpath_count" -gt 0 ]]; then
                    check_result "Multipath" "OK" "$mpath_count device(s)"
                else
                    check_result "Multipath" "WARNING" "Enabled but no devices"
                fi
            else
                check_result "Multipath" "WARNING" "Enabled but multipath-tools not installed"
            fi
        else
            check_result "Multipath" "SKIP" "Not enabled"
        fi
    fi

    # Check 11: PVE daemon status
    if systemctl is-active --quiet pvedaemon; then
        check_result "PVE daemon" "OK" "Running"
    else
        check_result "PVE daemon" "CRITICAL" "Not running"
    fi

    # Summary
    echo
    info "Health Summary:"
    if [[ $checks_skipped -gt 0 ]]; then
        echo "  Checks passed: $checks_passed/$checks_total ($checks_skipped not applicable)"
    else
        echo "  Checks passed: $checks_passed/$checks_total"
    fi

    if [[ $errors -gt 0 ]]; then
        error "Status: CRITICAL ($errors error(s), $warnings warning(s))"
        return 2
    elif [[ $warnings -gt 0 ]]; then
        warning "Status: WARNING ($warnings warning(s))"
        return 1
    else
        success "Status: HEALTHY"
        return 0
    fi
}

# Menu: Install specific version
menu_install_specific_version() {
    print_header "Install Specific Version"

    info "Fetching releases from GitHub..."
    local releases
    releases=$(get_all_releases) || {
        error "Failed to fetch releases"
        read -rp "Press Enter to continue..."
        return 1
    }

    echo
    echo "Available versions:"
    echo "$releases" | grep -Po '"tag_name":\s*"\K[^"]+' | sed 's/^v//' | head -20 | sed 's/^/  • v/'
    echo

    read -rp "Enter version number (e.g., 1.0.7): " version

    if [[ -z "$version" ]]; then
        warning "Installation cancelled"
        return 1
    fi

    if perform_installation "$version"; then
        # Prompt to configure storage after successful installation
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            echo
            read -rp "Would you like to configure storage now? (y/N): " response
            if [[ "$response" =~ ^[Yy] ]]; then
                menu_configure_storage
            else
                info "You can configure storage later from the main menu"
            fi
        fi
        read -rp "Press Enter to continue..."
        return 0  # Return success
    else
        read -rp "Press Enter to continue..."
        return 1  # Return failure
    fi
}

# ============================================================================
# CONFIGURATION WIZARD
# ============================================================================

# List all TrueNAS plugin storage names
list_truenas_storages() {
    if [[ ! -f "$STORAGE_CFG" ]]; then
        return 1
    fi

    grep "^truenasplugin:" "$STORAGE_CFG" 2>/dev/null | awk '{print $2}'
}

# Get all configuration values for a storage
# Returns associative array-like output: "key=value" per line
get_all_storage_config_values() {
    local storage_name="$1"

    if [[ ! -f "$STORAGE_CFG" ]]; then
        return 1
    fi

    # Extract the entire configuration block for this storage
    awk "/^truenasplugin: ${storage_name}\$/{flag=1; next} /^[a-z].*:/{flag=0} flag" "$STORAGE_CFG" | \
    grep -v "^\s*$" | \
    sed 's/^\s*//' | \
    awk '{print $1 "=" $2}'
}

# Validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Validate storage name format
validate_storage_name() {
    local name="$1"
    # Storage name should be alphanumeric with hyphens/underscores, no spaces
    if [[ $name =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi
    return 1
}

# Check if storage name already exists
storage_name_exists() {
    local name="$1"
    if [[ -f "$STORAGE_CFG" ]]; then
        grep -q "^truenasplugin: ${name}$" "$STORAGE_CFG"
    else
        return 1
    fi
}

# Validate NQN format (must start with nqn.YYYY-MM.)
validate_nqn() {
    local nqn="$1"
    if [[ $nqn =~ ^nqn\.[0-9]{4}-[0-9]{2}\. ]]; then
        return 0
    fi
    return 1
}

# Check if nvme-cli is installed
check_nvme_cli() {
    if command -v nvme &> /dev/null; then
        return 0
    fi
    return 1
}

# Get or generate host NQN
get_hostnqn() {
    local hostnqn=""

    # Check if hostnqn file exists
    if [[ -f /etc/nvme/hostnqn ]]; then
        hostnqn=$(cat /etc/nvme/hostnqn 2>/dev/null | tr -d '\n')
        if [[ -n "$hostnqn" ]]; then
            info "Found existing host NQN: $hostnqn" >&2
            read -rp "Use this host NQN? (Y/n): " use_existing
            if [[ ! "$use_existing" =~ ^[Nn] ]]; then
                echo "$hostnqn"
                return 0
            fi
        fi
    fi

    # Generate new hostnqn
    warning "No host NQN found or user declined existing one"
    read -rp "Generate new host NQN? (Y/n): " gen_new
    if [[ ! "$gen_new" =~ ^[Nn] ]]; then
        if check_nvme_cli; then
            mkdir -p /etc/nvme
            if nvme gen-hostnqn > /etc/nvme/hostnqn 2>/dev/null; then
                hostnqn=$(cat /etc/nvme/hostnqn 2>/dev/null | tr -d '\n')
                if [[ -z "$hostnqn" ]]; then
                    error "Generated hostnqn file is empty"
                    return 1
                fi
                success "Generated new host NQN: $hostnqn"
                echo "$hostnqn"
                return 0
            else
                error "Failed to generate host NQN"
                return 1
            fi
        else
            error "nvme-cli not available to generate host NQN"
            return 1
        fi
    fi

    # Manual entry with validation
    while true; do
        read -rp "Enter host NQN manually (or press Enter to skip): " hostnqn
        if [[ -z "$hostnqn" ]]; then
            warning "No host NQN configured"
            return 1
        fi
        if ! validate_nqn "$hostnqn"; then
            error "Invalid NQN format. Must start with nqn.YYYY-MM."
            continue
        fi
        break
    done
    echo "$hostnqn"
    return 0
}

# Check NVMe native multipath status
check_nvme_multipath() {
    if [[ -f /sys/module/nvme_core/parameters/multipath ]]; then
        local nvme_mp
        nvme_mp=$(cat /sys/module/nvme_core/parameters/multipath 2>/dev/null)
        if [[ "$nvme_mp" == "Y" ]]; then
            info "Native NVMe multipath: ENABLED"
            return 0
        else
            warning "Native NVMe multipath: DISABLED (may reduce redundancy)"
            info "To enable: echo 'options nvme_core multipath=Y' > /etc/modprobe.d/nvme.conf"
            info "Then reboot or reload nvme_core module"
            return 1
        fi
    else
        warning "Cannot detect NVMe multipath status (nvme_core module not loaded)"
        return 1
    fi
}

# Test TrueNAS API connectivity
test_truenas_api() {
    local ip="$1"
    local apikey="$2"

    local url="https://${ip}/api/v2.0/system/info"
    local tool
    tool=$(get_download_tool)

    printf "  Testing connection to TrueNAS at %s..." "$ip"
    start_spinner

    local response
    case "$tool" in
        curl)
            response=$(curl -sk -H "Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        wget)
            response=$(wget --no-check-certificate --quiet -O - --header="Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        *)
            stop_spinner
            echo ""
            return 1
            ;;
    esac

    stop_spinner
    echo ""
    if [[ -n "$response" ]] && echo "$response" | grep -q '"version"'; then
        local version
        version=$(echo "$response" | grep -Po '"version":\s*"\K[^"]+' 2>/dev/null)
        success "Connected to TrueNAS successfully (version: $version)"
        return 0
    else
        error "Failed to connect to TrueNAS API"
        return 1
    fi
}

# Verify dataset exists
verify_dataset() {
    local ip="$1"
    local apikey="$2"
    local dataset="$3"

    local url="https://${ip}/api/v2.0/pool/dataset?id=${dataset}"
    local tool
    tool=$(get_download_tool)

    printf "  Verifying dataset '%s'..." "$dataset"
    start_spinner

    local response
    local http_code
    case "$tool" in
        curl)
            response=$(curl -sk -w "\n%{http_code}" -H "Authorization: Bearer $apikey" "$url" 2>/dev/null)
            http_code=$(echo "$response" | tail -n1)
            response=$(echo "$response" | head -n-1)
            ;;
        wget)
            response=$(wget --no-check-certificate --quiet -O - --header="Authorization: Bearer $apikey" "$url" 2>/dev/null)
            http_code="200"
            ;;
        *)
            stop_spinner
            echo ""
            return 1
            ;;
    esac

    stop_spinner
    echo ""

    if [[ "$http_code" != "200" ]]; then
        warning "Dataset '$dataset' not found or not accessible"
        return 1
    fi

    if [[ -n "$response" ]] && echo "$response" | grep -q "\"id\": \"${dataset}\""; then
        success "Dataset '$dataset' verified"
        return 0
    else
        warning "Dataset '$dataset' not found or not accessible"
        return 1
    fi
}

# Discover available TrueNAS portals from network interfaces
discover_truenas_portals() {
    local ip="$1"
    local apikey="$2"
    local primary_ip="$3"

    local url="https://${ip}/api/v2.0/interface"
    local tool
    tool=$(get_download_tool)

    local response
    case "$tool" in
        curl)
            response=$(curl -sk -H "Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        wget)
            response=$(wget --no-check-certificate --quiet -O - --header="Authorization: Bearer $apikey" "$url" 2>/dev/null)
            ;;
        *)
            return 1
            ;;
    esac

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Extract IP addresses from interfaces, excluding the primary IP
    # Parse JSON to find all "address" fields with IPv4 addresses
    local portals
    portals=$(echo "$response" | grep -Po '"address":\s*"\K[0-9.]+' | grep -v "^127\." | grep -v "^${primary_ip}$" | sort -u)

    if [[ -z "$portals" ]]; then
        return 1
    fi

    echo "$portals"
    return 0
}

# Backup storage.cfg
backup_storage_cfg() {
    if [[ ! -f "$STORAGE_CFG" ]]; then
        log "INFO" "No storage.cfg to backup"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${BACKUP_DIR}/storage.cfg.backup.${timestamp}"

    cp "$STORAGE_CFG" "$backup_file" || {
        error "Failed to create storage.cfg backup"
        return 1
    }

    success "Storage config backed up: $backup_file"
    log "INFO" "Storage config backed up: $backup_file"
    return 0
}

# Generate storage configuration block
generate_storage_config() {
    local name="$1"
    local ip="$2"
    local apikey="$3"
    local dataset="$4"
    local target_or_nqn="$5"  # target_iqn for iSCSI, subsystem_nqn for NVMe
    local portal="${6:-}"
    local blocksize="${7:-16k}"
    local sparse="${8:-1}"
    local use_multipath="${9:-}"
    local portals="${10:-}"
    local transport_mode="${11:-iscsi}"  # Default to iscsi for backward compatibility
    local hostnqn="${12:-}"

    cat <<EOF
truenasplugin: ${name}
	api_host ${ip}
	api_key ${apikey}
	dataset ${dataset}
EOF

    # Add transport mode if not default iSCSI
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        echo "	transport_mode nvme-tcp"
        echo "	subsystem_nqn ${target_or_nqn}"
    else
        echo "	target_iqn ${target_or_nqn}"
    fi

    echo "	api_insecure 1"
    echo "	shared 1"

    if [[ -n "$portal" ]]; then
        echo "	discovery_portal ${portal}"
    fi

    if [[ -n "$blocksize" ]]; then
        echo "	zvol_blocksize ${blocksize}"
    fi

    if [[ -n "$sparse" ]]; then
        echo "	tn_sparse ${sparse}"
    fi

    # Only add use_multipath for iSCSI (NVMe uses native multipath)
    if [[ -n "$use_multipath" ]] && [[ "$transport_mode" == "iscsi" ]]; then
        echo "	use_multipath ${use_multipath}"
    fi

    if [[ -n "$portals" ]]; then
        echo "	portals ${portals}"
    fi

    # Add hostnqn for NVMe if provided
    if [[ -n "$hostnqn" ]] && [[ "$transport_mode" == "nvme-tcp" ]]; then
        echo "	hostnqn ${hostnqn}"
    fi

    # Always add content type
    echo "	content images"
}

# Add storage configuration to storage.cfg
add_storage_config() {
    local config="$1"

    # Backup first
    backup_storage_cfg || {
        error "Failed to backup storage.cfg"
        return 1
    }

    # Append configuration
    echo "" >> "$STORAGE_CFG"
    echo "$config" >> "$STORAGE_CFG"

    success "Storage configuration added to $STORAGE_CFG"
    log "INFO" "Storage configuration added"
    return 0
}

# Update existing storage configuration in storage.cfg
update_storage_config() {
    local storage_name="$1"
    local new_config="$2"

    if [[ ! -f "$STORAGE_CFG" ]]; then
        error "Storage configuration file not found: $STORAGE_CFG"
        return 1
    fi

    # Backup first
    backup_storage_cfg || {
        error "Failed to backup storage.cfg"
        return 1
    }

    # Create temporary file
    local temp_file="${STORAGE_CFG}.tmp.$$"

    # Remove old storage block and write everything except that storage
    awk -v storage="truenasplugin: ${storage_name}" '
        $0 ~ "^" storage "$" { skip=1; next }
        /^[a-z].*:/ { skip=0 }
        !skip { print }
    ' "$STORAGE_CFG" > "$temp_file"

    # Append new configuration
    echo "" >> "$temp_file"
    echo "$new_config" >> "$temp_file"

    # Replace original file
    if mv "$temp_file" "$STORAGE_CFG"; then
        success "Storage configuration updated in $STORAGE_CFG"
        log "INFO" "Storage '$storage_name' configuration updated"
        return 0
    else
        error "Failed to update storage configuration"
        rm -f "$temp_file"
        return 1
    fi
}

# Edit existing storage configuration
menu_edit_storage() {
    local storage_name="$1"

    print_header "Edit Storage Configuration: $storage_name"

    info "Loading existing configuration for '$storage_name'..."
    echo

    # Load all existing configuration values
    declare -A config_values
    while IFS='=' read -r key value; do
        config_values["$key"]="$value"
    done < <(get_all_storage_config_values "$storage_name")

    # Display immutable fields (read-only)
    info "Current Configuration (read-only fields):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Transport mode (immutable)
    local transport_mode="${config_values[transport_mode]:-iscsi}"
    echo "  Transport mode:     $transport_mode ${c3}(cannot be changed)${c0}"

    # Dataset (immutable - changing would orphan volumes)
    local dataset="${config_values[dataset]}"
    echo "  Dataset:            $dataset ${c3}(cannot be changed)${c0}"

    # Block size (immutable - cannot change after volumes created)
    local blocksize="${config_values[zvol_blocksize]:-16k}"
    echo "  Block size:         $blocksize ${c3}(cannot be changed)${c0}"

    # Transport-specific immutable fields
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        local subsystem_nqn="${config_values[subsystem_nqn]}"
        echo "  Subsystem NQN:      $subsystem_nqn ${c3}(cannot be changed)${c0}"
    else
        local target_iqn="${config_values[target_iqn]}"
        echo "  Target IQN:         $target_iqn ${c3}(cannot be changed)${c0}"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    warning "Note: Fields marked as 'cannot be changed' are immutable to prevent orphaning existing volumes"
    echo

    # Prompt for mutable fields with current values as defaults
    info "Editable Configuration:"
    echo

    # TrueNAS API settings
    local current_api_host="${config_values[api_host]}"
    local truenas_ip
    read -rp "TrueNAS IP address [$current_api_host]: " truenas_ip
    truenas_ip="${truenas_ip:-$current_api_host}"

    if [[ -z "$truenas_ip" ]]; then
        error "TrueNAS IP address cannot be empty"
        return 1
    fi

    if ! validate_ip "$truenas_ip"; then
        error "Invalid IP address format"
        return 1
    fi

    # API Key
    local current_api_key="${config_values[api_key]}"
    info "Current API key: ${current_api_key:0:20}... (hidden)"
    local api_key
    read -rp "New TrueNAS API key (press Enter to keep current): " api_key
    api_key="${api_key:-$current_api_key}"

    if [[ -z "$api_key" ]]; then
        error "API key cannot be empty"
        return 1
    fi

    # Test connectivity
    if ! test_truenas_api "$truenas_ip" "$api_key"; then
        error "Failed to connect to TrueNAS. Please check IP and API key."
        read -rp "Continue anyway? (y/N): " choice
        [[ "$choice" =~ ^[Yy] ]] || return 1
    fi

    # Portal configuration
    local current_portal="${config_values[discovery_portal]}"
    local default_port
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        default_port="4420"
    else
        default_port="3260"
    fi

    local portal
    read -rp "Portal IP:port [$current_portal]: " portal
    portal="${portal:-$current_portal}"

    if [[ -z "$portal" ]]; then
        portal="${truenas_ip}:${default_port}"
    elif [[ ! "$portal" =~ : ]]; then
        portal="${portal}:${default_port}"
    fi

    # Sparse volumes
    local current_sparse="${config_values[tn_sparse]:-1}"
    local sparse
    read -rp "Enable sparse volumes? (0/1) [$current_sparse]: " sparse
    sparse="${sparse:-$current_sparse}"

    # Multipath configuration
    echo
    info "Multipath Configuration:"
    local current_use_multipath="${config_values[use_multipath]:-0}"
    local current_portals="${config_values[portals]:-}"

    if [[ "$transport_mode" == "iscsi" ]]; then
        echo "  Current multipath setting: $current_use_multipath"
        if [[ -n "$current_portals" ]]; then
            echo "  Current portals: $current_portals"
        fi
        echo

        local use_multipath
        read -rp "Enable multipath I/O? (0/1) [$current_use_multipath]: " use_multipath
        use_multipath="${use_multipath:-$current_use_multipath}"

        local portals="$current_portals"
        if [[ "$use_multipath" == "1" ]]; then
            read -rp "Additional portals (comma-separated IP:port) [$current_portals]: " portals
            portals="${portals:-$current_portals}"
        else
            portals=""
        fi
    else
        # NVMe/TCP - only portals matter
        echo "  Current portals: ${current_portals:-none}"
        echo
        local portals
        read -rp "Portals for native multipath (comma-separated IP:port) [$current_portals]: " portals
        portals="${portals:-$current_portals}"
        use_multipath=""  # Not used for NVMe
    fi

    # Host NQN for NVMe (optional, can be changed)
    local hostnqn="${config_values[hostnqn]:-}"
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        echo
        info "Current host NQN: ${hostnqn:-system default}"
        read -rp "Update host NQN? (y/N): " update_hostnqn
        if [[ "$update_hostnqn" =~ ^[Yy] ]]; then
            read -rp "New host NQN: " hostnqn
        fi
    fi

    # Generate updated configuration
    echo
    info "Updated Configuration Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local config
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        local subsystem_nqn="${config_values[subsystem_nqn]}"
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$subsystem_nqn" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "$hostnqn")
    else
        local target_iqn="${config_values[target_iqn]}"
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$target_iqn" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "")
    fi
    echo "$config"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    read -rp "Apply these changes to $STORAGE_CFG? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        warning "Configuration changes cancelled"
        return 1
    fi

    # Update configuration (remove old, add new)
    if update_storage_config "$storage_name" "$config"; then
        echo
        success "Storage configuration updated successfully!"
        info "Storage '$storage_name' has been reconfigured"
        echo
        info "Next steps:"
        echo "  1. Restart pvedaemon and pveproxy if needed"
        echo "  2. Check storage status: pvesm status"
        echo "  3. Verify connectivity with existing volumes"
        echo
        read -rp "Press Enter to continue..."
    else
        error "Failed to update configuration"
        return 1
    fi

    return 0
}

# Configuration wizard
menu_configure_storage() {
    print_header "Storage Configuration Wizard"

    info "This wizard will help you configure TrueNAS storage for Proxmox"
    echo

    # Check for existing storage entries
    local existing_storages
    existing_storages=$(list_truenas_storages 2>/dev/null || true)

    local storage_name=""

    if [[ -n "$existing_storages" ]]; then
        # Count existing storages
        local storage_count
        storage_count=$(echo "$existing_storages" | wc -l)

        # Present menu (don't show storage list yet)
        info "Found $storage_count existing TrueNAS storage configuration(s)"
        echo
        info "What would you like to do?"
        echo "  1) Edit an existing storage"
        echo "  2) Add a new storage"
        echo "  0) Cancel"
        echo

        local menu_choice
        while true; do
            read -rp "Select option [0-2]: " menu_choice
            if [[ "$menu_choice" =~ ^[0-2]$ ]]; then
                break
            else
                error "Invalid choice. Please enter 0, 1, or 2"
            fi
        done

        case "$menu_choice" in
            0)
                info "Configuration cancelled"
                return 0
                ;;
            1)
                # Edit mode - NOW show the storage list
                echo
                info "Available storage configurations:"
                local idx=1
                local -a storage_array=()
                while IFS= read -r storage; do
                    echo "  $idx) $storage"
                    storage_array+=("$storage")
                    ((idx++))
                done <<< "$existing_storages"
                echo

                local storage_idx
                while true; do
                    read -rp "Select storage to edit [1-${#storage_array[@]}] or 0 to cancel: " storage_idx
                    if [[ "$storage_idx" == "0" ]]; then
                        info "Configuration cancelled"
                        return 0
                    elif [[ "$storage_idx" =~ ^[0-9]+$ ]] && [[ "$storage_idx" -ge 1 ]] && [[ "$storage_idx" -le "${#storage_array[@]}" ]]; then
                        storage_name="${storage_array[$((storage_idx-1))]}"
                        # Call edit function and return
                        menu_edit_storage "$storage_name"
                        return $?
                    else
                        error "Invalid selection. Please enter a number between 1 and ${#storage_array[@]}"
                    fi
                done
                ;;
            2)
                # Add new storage mode - continue with existing workflow below
                ;;
        esac
    fi

    # Continue with "Add New Storage" workflow
    # Prompt for storage name
    local storage_name
    while true; do
        read -rp "Storage name (e.g., truenas-main): " storage_name
        if [[ -z "$storage_name" ]]; then
            error "Storage name cannot be empty"
            continue
        fi
        if ! validate_storage_name "$storage_name"; then
            error "Invalid storage name. Use only letters, numbers, hyphens, and underscores"
            continue
        fi
        if storage_name_exists "$storage_name"; then
            error "Storage name '$storage_name' already exists in $STORAGE_CFG"
            read -rp "Choose a different name? (Y/n): " choice
            [[ ! "$choice" =~ ^[Nn] ]] && continue || return 1
        fi
        break
    done

    # TrueNAS IP
    local truenas_ip
    while true; do
        read -rp "TrueNAS IP address: " truenas_ip
        if validate_ip "$truenas_ip"; then
            break
        else
            error "Invalid IP address format"
        fi
    done

    # API Key
    local api_key
    read -rp "TrueNAS API key: " api_key
    if [[ -z "$api_key" ]]; then
        error "API key cannot be empty"
        return 1
    fi

    # Test connectivity
    if ! test_truenas_api "$truenas_ip" "$api_key"; then
        error "Failed to connect to TrueNAS. Please check IP and API key."
        read -rp "Continue anyway? (y/N): " choice
        [[ "$choice" =~ ^[Yy] ]] || return 1
    fi

    # Dataset
    local dataset
    while true; do
        read -rp "ZFS dataset path (e.g., tank/proxmox): " dataset
        if [[ -z "$dataset" ]]; then
            error "Dataset cannot be empty"
            continue
        fi

        # Verify dataset if API connection worked
        if ! verify_dataset "$truenas_ip" "$api_key" "$dataset"; then
            echo
            warning "Dataset verification failed. The dataset may not exist or may not be accessible."
            read -rp "Continue anyway? (y/N): " continue_choice
            if [[ "$continue_choice" =~ ^[Yy] ]]; then
                warning "Proceeding with unverified dataset '$dataset'"
                break
            else
                echo
                info "Please enter a different dataset name"
                continue
            fi
        fi
        break
    done

    # Transport mode selection
    echo
    info "Select transport protocol:"
    echo "  1) iSCSI (traditional, widely compatible)"
    echo "  2) NVMe/TCP (modern, lower latency)"
    read -rp "Transport mode (1-2) [1]: " transport_choice
    transport_choice=${transport_choice:-1}

    local transport_mode
    case "$transport_choice" in
        1) transport_mode="iscsi" ;;
        2) transport_mode="nvme-tcp" ;;
        *)
            error "Invalid choice, defaulting to iSCSI"
            transport_mode="iscsi"
            ;;
    esac

    # Transport-specific configuration
    local target=""
    local subsystem_nqn=""
    local hostnqn=""

    if [[ "$transport_mode" == "iscsi" ]]; then
        # iSCSI Target
        read -rp "iSCSI target (e.g., iqn.2025-01.com.truenas:target0): " target
        if [[ -z "$target" ]]; then
            error "iSCSI target cannot be empty"
            return 1
        fi
    else
        # NVMe/TCP configuration
        # Check nvme-cli
        if ! check_nvme_cli; then
            warning "nvme-cli package is not installed"
            info "NVMe/TCP requires nvme-cli for management"
            read -rp "Install nvme-cli now? (Y/n): " install_nvme
            if [[ ! "$install_nvme" =~ ^[Nn] ]]; then
                info "Installing nvme-cli..."
                if ! apt-get update; then
                    error "Failed to update package lists (check network/repositories)"
                    return 1
                fi
                if ! apt-get install -y nvme-cli; then
                    error "Failed to install nvme-cli package"
                    return 1
                fi
                if ! check_nvme_cli; then
                    error "nvme-cli installed but 'nvme' command not found in PATH"
                    info "Try running: hash -r  # to refresh PATH"
                    return 1
                fi
                success "nvme-cli installed successfully"
            else
                warning "Proceeding without nvme-cli (some features may not work)"
            fi
        fi

        # Subsystem NQN
        while true; do
            read -rp "NVMe subsystem NQN (e.g., nqn.2005-10.org.freenas.ctl:proxmox): " subsystem_nqn
            if [[ -z "$subsystem_nqn" ]]; then
                error "Subsystem NQN cannot be empty"
                continue
            fi
            if ! validate_nqn "$subsystem_nqn"; then
                error "Invalid NQN format. Must start with nqn.YYYY-MM."
                continue
            fi
            break
        done

        # Host NQN
        hostnqn=$(get_hostnqn)
        if [[ -z "$hostnqn" ]]; then
            warning "No host NQN configured (plugin will use system default)"
        fi

        # Check native multipath
        echo
        check_nvme_multipath || true
    fi

    # Portal (optional) - set default port based on transport
    local portal
    local default_port
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        default_port="4420"
    else
        default_port="3260"
    fi

    read -rp "Portal IP (optional, press Enter to use TrueNAS IP): " portal
    if [[ -z "$portal" ]]; then
        portal="${truenas_ip}:${default_port}"
    elif [[ ! "$portal" =~ : ]]; then
        # Add default port if not specified
        portal="${portal}:${default_port}"
    fi

    # Blocksize (optional)
    local blocksize
    read -rp "Block size [16k]: " blocksize
    blocksize="${blocksize:-16k}"

    # Sparse (optional)
    local sparse
    read -rp "Enable sparse volumes? (0/1) [1]: " sparse
    sparse="${sparse:-1}"

    # Multipath configuration
    echo
    info "Advanced Options:"
    local use_multipath=""
    local portals=""
    read -rp "Enable multipath I/O for redundancy/load balancing? (y/N): " enable_mp

    if [[ "$enable_mp" =~ ^[Yy] ]]; then
        if [[ "$transport_mode" == "iscsi" ]]; then
            # Check for multipath-tools package (iSCSI only)
            if ! command -v multipath &> /dev/null; then
                warning "multipath-tools package is not installed"
                info "Multipath requires: apt-get install multipath-tools"
                read -rp "Continue configuring multipath anyway? (y/N): " continue_mp
                if [[ ! "$continue_mp" =~ ^[Yy] ]]; then
                    info "Multipath disabled"
                else
                    use_multipath="1"
                fi
            else
                use_multipath="1"
            fi
        else
            # NVMe/TCP uses native multipath
            info "NVMe/TCP uses native kernel multipath (no dm-multipath required)"
            use_multipath=""  # Don't set use_multipath flag for NVMe
        fi

        # If multipath is enabled (or for NVMe), discover and select additional portals
        if [[ "$use_multipath" == "1" ]] || [[ "$transport_mode" == "nvme-tcp" ]]; then
            echo
            info "Discovering available portals from TrueNAS..."
            local discovered_portals
            discovered_portals=$(discover_truenas_portals "$truenas_ip" "$api_key" "$truenas_ip")

            if [[ -n "$discovered_portals" ]]; then
                success "Found available portal IPs:"
                local portal_array=()
                local idx=1
                while IFS= read -r ip; do
                    echo "  $idx) $ip"
                    portal_array+=("$ip")
                    ((idx++))
                done <<< "$discovered_portals"

                echo
                info "Select additional portals for multipath (space-separated numbers, e.g., '1 2')"
                info "Note: Portals should be on different subnets for proper multipath operation"
                read -rp "Portal numbers (or press Enter to skip): " portal_choices

                if [[ -n "$portal_choices" ]]; then
                    local selected_portals=()
                    local invalid_choices=()
                    for choice in $portal_choices; do
                        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt "$idx" ]]; then
                            selected_portals+=("${portal_array[$((choice-1))]}:${default_port}")
                        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
                            invalid_choices+=("$choice")
                        fi
                    done

                    if [[ ${#invalid_choices[@]} -gt 0 ]]; then
                        warning "Invalid selections ignored: ${invalid_choices[*]}"
                    fi

                    if [[ ${#selected_portals[@]} -gt 0 ]]; then
                        portals=$(IFS=,; echo "${selected_portals[*]}")
                        success "Selected portals: $portals"
                    else
                        warning "No valid portals selected"
                    fi
                fi
            else
                warning "Could not discover portals automatically"
                info "You can enter portals manually"
            fi

            # Fallback to manual entry
            if [[ -z "$portals" ]]; then
                echo
                info "Enter additional portals manually (comma-separated IP:port)"
                if [[ "$transport_mode" == "nvme-tcp" ]]; then
                    info "Example: 192.168.10.101:4420,192.168.10.102:4420"
                else
                    info "Example: 192.168.10.101:3260,192.168.10.102:3260"
                fi
                read -rp "Additional portals (or press Enter to skip): " portals

                # Validate manual portal entry format
                if [[ -n "$portals" ]]; then
                    local portal_valid=true
                    IFS=',' read -ra portal_list <<< "$portals"
                    for p in "${portal_list[@]}"; do
                        if [[ ! "$p" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+$ ]]; then
                            warning "Invalid portal format: $p"
                            portal_valid=false
                        fi
                    done
                    if [[ "$portal_valid" == "false" ]]; then
                        warning "Clearing invalid portal entries"
                        portals=""
                    fi
                fi

                if [[ -z "$portals" ]]; then
                    if [[ "$transport_mode" == "iscsi" && "$use_multipath" == "1" ]]; then
                        warning "No additional portals configured - multipath will not function"
                        warning "You must configure multiple portals for multipath to work"
                    elif [[ "$transport_mode" == "nvme-tcp" ]]; then
                        info "Using single portal (you can add more later for native multipath redundancy)"
                    fi
                fi
            fi
        fi
    else
        use_multipath="0"
    fi

    # Generate configuration
    echo
    info "Configuration summary:"
    info "Transport mode: ${transport_mode}"
    echo "─────────────────────────────────────────────────────────"
    local config
    if [[ "$transport_mode" == "nvme-tcp" ]]; then
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$subsystem_nqn" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "$hostnqn")
    else
        config=$(generate_storage_config "$storage_name" "$truenas_ip" "$api_key" "$dataset" "$target" "$portal" "$blocksize" "$sparse" "$use_multipath" "$portals" "$transport_mode" "")
    fi
    echo "$config"
    echo "─────────────────────────────────────────────────────────"
    echo

    read -rp "Add this configuration to $STORAGE_CFG? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        warning "Configuration cancelled"
        return 1
    fi

    # Add configuration
    if add_storage_config "$config"; then
        echo
        success "Storage configured successfully!"
        info "You can now use '$storage_name' storage in Proxmox"
        echo
        info "Next steps:"
        echo "  1. Test the storage by creating a VM disk:"
        echo "     qm create 999 --name test-vm && qm set 999 --scsi0 ${storage_name}:10"
        echo "  2. Check storage status: pvesm status"
        echo "  3. View storage details: pvesm list ${storage_name}"

        # Add multipath-specific next steps if enabled
        if [[ "$use_multipath" == "1" ]]; then
            echo "  4. Verify multipath configuration: multipath -ll"
            echo "  5. Check multipath service status: systemctl status multipathd"
            if ! command -v multipath &> /dev/null; then
                echo "  6. Install multipath-tools: apt-get install multipath-tools"
            fi
        fi
    else
        error "Failed to add configuration"
        return 1
    fi

    read -rp "Press Enter to continue..."
}

# ============================================================================
# ROLLBACK FUNCTIONALITY
# ============================================================================

# Restore from backup
restore_plugin_from_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
        return 1
    fi

    info "Restoring plugin from backup..."

    # Validate backup before restoring
    if ! validate_plugin "$backup_file"; then
        error "Backup file validation failed"
        return 1
    fi

    # Create a backup of current version before rollback
    backup_plugin || warning "Could not backup current version"

    # Restore the backup
    cp "$backup_file" "$PLUGIN_FILE" || {
        error "Failed to restore backup"
        return 1
    }

    # Set correct permissions
    chown root:root "$PLUGIN_FILE"
    chmod 644 "$PLUGIN_FILE"

    success "Plugin restored from backup"
    log "INFO" "Plugin restored from: $backup_file"

    # Restart services
    restart_pve_services || warning "Services may need manual restart"

    return 0
}

# Menu: Rollback
menu_rollback() {
    print_header "Rollback to Previous Version"

    info "Searching for available backups..."
    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        info "Backups are stored in: $BACKUP_DIR"
        read -rp "Press Enter to continue..."
        return 1
    fi

    echo
    echo "Available backups:"
    echo "─────────────────────────────────────────────────────────"

    local -a backup_array
    local index=1
    while IFS= read -r backup; do
        # Extract version and timestamp from filename
        local filename
        filename=$(basename "$backup")
        # Format: TrueNASPlugin.pm.backup.VERSION.TIMESTAMP
        # Remove prefix to get VERSION.TIMESTAMP
        local version_timestamp
        version_timestamp=$(echo "$filename" | sed 's/TrueNASPlugin\.pm\.backup\.//')
        # Split on last underscore (timestamp starts with YYYYMMDD_)
        local version
        version=$(echo "$version_timestamp" | sed 's/\.[0-9]*_[0-9]*$//')
        local timestamp
        timestamp=$(echo "$version_timestamp" | sed 's/.*\.\([0-9]*_[0-9]*\)$/\1/')

        # Format timestamp for display
        local display_time
        if [[ "$timestamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
            display_time="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        else
            display_time="$timestamp"
        fi

        echo "  $index) Version $version - $display_time"
        backup_array+=("$backup")
        ((index++))
    done <<< "$backups"

    echo "  0) Cancel"
    echo "─────────────────────────────────────────────────────────"
    echo

    local choice
    choice=$(read_choice $((index - 1)))

    if [[ "$choice" -eq 0 ]]; then
        info "Rollback cancelled"
        return 0
    fi

    local selected_backup="${backup_array[$((choice - 1))]}"

    echo
    warning "This will replace the current plugin with the selected backup"
    read -rp "Continue with rollback? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Rollback cancelled"
        read -rp "Press Enter to continue..."
        return 0
    fi

    if restore_plugin_from_backup "$selected_backup"; then
        success "Rollback completed successfully"

        # Show cluster warning if applicable
        if is_cluster_node; then
            show_cluster_warning
        fi
    else
        error "Rollback failed"
    fi

    read -rp "Press Enter to continue..."
}

# ============================================================================
# BACKUP MANAGEMENT
# ============================================================================

# View all backups with detailed information
view_all_backups() {
    print_header "Backup Files"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        info "Backups are stored in: $BACKUP_DIR"
        return 1
    fi

    local stats
    stats=$(scan_backups)
    IFS=':' read -r count total_size oldest_age newest_age <<< "$stats"

    echo
    echo "Total: $count backup(s) - $(format_size "$total_size")"
    echo "─────────────────────────────────────────────────────────────────────────────"
    printf "%-6s %-15s %-20s %-12s %s\n" "No." "Version" "Created" "Size" "Age"
    echo "─────────────────────────────────────────────────────────────────────────────"

    local index=1
    while IFS= read -r backup; do
        local filename
        filename=$(basename "$backup")

        # Extract version and timestamp
        local version_timestamp
        version_timestamp=$(echo "$filename" | sed 's/TrueNASPlugin\.pm\.backup\.//')
        local version
        version=$(echo "$version_timestamp" | sed 's/\.[0-9]*_[0-9]*$//')
        local timestamp
        timestamp=$(echo "$version_timestamp" | sed 's/.*\.\([0-9]*_[0-9]*\)$/\1/')

        # Format timestamp for display
        local display_time
        if [[ "$timestamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
            display_time="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}"
        else
            display_time="$timestamp"
        fi

        # Get file size
        local size
        size=$(stat -c %s "$backup" 2>/dev/null || stat -f %z "$backup" 2>/dev/null)

        # Get age
        local age
        age=$(backup_age_days "$backup")

        printf "%-6s %-15s %-20s %-12s %s\n" \
            "$index)" \
            "$version" \
            "$display_time" \
            "$(format_size "$size")" \
            "$(format_age "$age")"

        ((index++))
    done <<< "$backups"

    echo "─────────────────────────────────────────────────────────────────────────────"
    echo
}

# Delete old backups by age threshold
delete_old_backups() {
    print_header "Delete Old Backups"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        return 1
    fi

    echo
    read -rp "Delete backups older than how many days? (default: 30): " age_threshold
    age_threshold=${age_threshold:-30}

    # Validate input
    if ! [[ "$age_threshold" =~ ^[0-9]+$ ]]; then
        error "Invalid input. Please enter a number."
        return 1
    fi

    # Find backups older than threshold
    local old_backups=()
    while IFS= read -r backup; do
        local age
        age=$(backup_age_days "$backup")
        if [[ "$age" -gt "$age_threshold" ]]; then
            old_backups+=("$backup")
        fi
    done <<< "$backups"

    if [[ "${#old_backups[@]}" -eq 0 ]]; then
        info "No backups older than $age_threshold days found"
        return 0
    fi

    echo
    warning "Found ${#old_backups[@]} backup(s) older than $age_threshold days:"
    echo
    for backup in "${old_backups[@]}"; do
        local age
        age=$(backup_age_days "$backup")
        echo "  • $(basename "$backup") - $(format_age "$age")"
    done
    echo

    read -rp "Delete these backups? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Deletion cancelled"
        return 0
    fi

    # Delete old backups
    local deleted=0
    local failed=0
    for backup in "${old_backups[@]}"; do
        if rm -f "$backup" 2>/dev/null; then
            ((deleted++))
            log "INFO" "Deleted old backup: $backup"
        else
            ((failed++))
            warning "Failed to delete: $(basename "$backup")"
        fi
    done

    if [[ "$deleted" -gt 0 ]]; then
        success "Deleted $deleted backup(s)"
    fi

    if [[ "$failed" -gt 0 ]]; then
        warning "Failed to delete $failed backup(s)"
    fi
}

# Keep only latest N backups
keep_latest_backups() {
    print_header "Keep Latest N Backups"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        return 1
    fi

    local total_count
    total_count=$(echo "$backups" | wc -l)

    echo
    echo "Current backup count: $total_count"
    read -rp "How many backups would you like to keep? (default: 5): " keep_count
    keep_count=${keep_count:-5}

    # Validate input
    if ! [[ "$keep_count" =~ ^[0-9]+$ ]]; then
        error "Invalid input. Please enter a number."
        return 1
    fi

    if [[ "$keep_count" -ge "$total_count" ]]; then
        info "No backups need to be deleted (keeping $keep_count, have $total_count)"
        return 0
    fi

    local delete_count=$((total_count - keep_count))

    echo
    warning "This will delete $delete_count backup(s), keeping only the $keep_count most recent"
    read -rp "Continue? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Deletion cancelled"
        return 0
    fi

    # Get backups to delete (oldest ones)
    local -a backups_to_delete
    mapfile -t backups_to_delete < <(echo "$backups" | tail -n "$delete_count")

    # Delete backups
    local deleted=0
    local failed=0
    for backup in "${backups_to_delete[@]}"; do
        if rm -f "$backup" 2>/dev/null; then
            ((deleted++))
            log "INFO" "Deleted backup: $backup"
        else
            ((failed++))
            warning "Failed to delete: $(basename "$backup")"
        fi
    done

    if [[ "$deleted" -gt 0 ]]; then
        success "Deleted $deleted backup(s), kept $keep_count most recent"
    fi

    if [[ "$failed" -gt 0 ]]; then
        warning "Failed to delete $failed backup(s)"
    fi
}

# Delete all backups with strong confirmation
delete_all_backups() {
    print_header "Delete All Backups"

    local backups
    backups=$(list_backups 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        warning "No backups found"
        return 1
    fi

    local total_count
    total_count=$(echo "$backups" | wc -l)

    echo
    warning "This will permanently delete ALL $total_count backup(s)!"
    warning "This action cannot be undone!"
    echo
    echo "Type 'DELETE ALL' to confirm:"
    read -r confirm

    if [[ "$confirm" != "DELETE ALL" ]]; then
        info "Deletion cancelled"
        return 0
    fi

    # Delete all backups
    local deleted=0
    local failed=0
    while IFS= read -r backup; do
        if rm -f "$backup" 2>/dev/null; then
            ((deleted++))
            log "INFO" "Deleted backup: $backup"
        else
            ((failed++))
            warning "Failed to delete: $(basename "$backup")"
        fi
    done <<< "$backups"

    if [[ "$deleted" -gt 0 ]]; then
        success "Deleted all $deleted backup(s)"
    fi

    if [[ "$failed" -gt 0 ]]; then
        warning "Failed to delete $failed backup(s)"
    fi
}

# Backup management submenu
menu_manage_backups() {
    while true; do
        print_header "Manage Backups"

        local stats
        stats=$(scan_backups)
        IFS=':' read -r count total_size oldest_age newest_age <<< "$stats"

        if [[ "$count" -eq 0 ]]; then
            warning "No backups found"
            info "Backups are stored in: $BACKUP_DIR"
            read -rp "Press Enter to return to main menu..."
            return 0
        fi

        # Show backup statistics
        echo
        echo "Backup Statistics:"
        echo "─────────────────────────────────────────────────────────"
        echo "  Total backups: $count"
        echo "  Total size: $(format_size "$total_size")"
        echo "  Oldest backup: $(format_age "$oldest_age")"
        echo "  Newest backup: $(format_age "$newest_age")"
        echo "─────────────────────────────────────────────────────────"
        echo

        show_menu "Backup Management" \
            "View all backups" \
            "Delete old backups (by age)" \
            "Keep only latest N backups" \
            "Delete all backups"

        local choice
        choice=$(read_choice 4)

        case $choice in
            0)
                return 0
                ;;
            1)
                view_all_backups
                read -rp "Press Enter to continue..."
                ;;
            2)
                delete_old_backups
                read -rp "Press Enter to continue..."
                ;;
            3)
                keep_latest_backups
                read -rp "Press Enter to continue..."
                ;;
            4)
                delete_all_backups
                read -rp "Press Enter to continue..."
                ;;
        esac
    done
}

# ============================================================================
# UNINSTALLATION
# ============================================================================

# Remove storage configuration
remove_storage_config() {
    local storage_name="$1"

    if [[ ! -f "$STORAGE_CFG" ]]; then
        info "No storage.cfg file found"
        return 0
    fi

    # Backup first
    backup_storage_cfg || {
        error "Failed to backup storage.cfg"
        return 1
    }

    info "Removing storage '$storage_name' from configuration..."

    # Create temporary file
    local temp_file="${STORAGE_CFG}.tmp"

    # Remove the storage block (truenas: line and all indented lines after it)
    awk -v storage="truenas: ${storage_name}" '
        $0 ~ "^" storage "$" { skip=1; next }
        /^[^ \t]/ { skip=0 }
        !skip { print }
    ' "$STORAGE_CFG" > "$temp_file"

    mv "$temp_file" "$STORAGE_CFG"
    success "Storage configuration removed"
    return 0
}

# List all TrueNAS storage entries
list_truenas_storage() {
    if [[ ! -f "$STORAGE_CFG" ]]; then
        return 1
    fi

    grep "^truenas:" "$STORAGE_CFG" | sed 's/^truenas: //' || return 1
}

# Uninstall plugin
uninstall_plugin() {
    local remove_config="${1:-false}"

    print_header "Uninstalling TrueNAS Plugin"

    # Backup before removing
    backup_plugin || warning "Could not create backup before uninstallation"

    # Remove plugin file
    if [[ -f "$PLUGIN_FILE" ]]; then
        rm "$PLUGIN_FILE" || {
            error "Failed to remove plugin file"
            return 1
        }
        success "Plugin file removed"
    else
        info "Plugin file not found (already removed)"
    fi

    # Handle storage configuration
    if [[ "$remove_config" == "true" ]]; then
        local storages
        storages=$(list_truenas_storage)

        if [[ -n "$storages" ]]; then
            echo
            info "Found TrueNAS storage configurations:"
            echo "$storages" | while read -r storage; do
                echo "  • $storage"
            done
            echo

            read -rp "Remove all TrueNAS storage configurations? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy] ]]; then
                echo "$storages" | while read -r storage; do
                    remove_storage_config "$storage"
                done
            fi
        fi
    fi

    # Restart services
    restart_pve_services || warning "Services may need manual restart"

    echo
    success "TrueNAS Plugin uninstalled successfully"
    echo
    info "Important notes:"
    echo "  • Plugin backup saved in: $BACKUP_DIR"
    echo "  • Data on TrueNAS is NOT affected"
    echo "  • iSCSI extents and targets remain on TrueNAS"
    echo "  • You can reinstall the plugin at any time"

    if [[ "$remove_config" != "true" ]]; then
        echo
        info "Storage configuration remains in $STORAGE_CFG"
        info "Remove manually if no longer needed"
    fi

    return 0
}

# Menu: Uninstall
menu_uninstall() {
    print_header "Uninstall TrueNAS Plugin"

    warning "This will remove the TrueNAS plugin from Proxmox"
    echo
    info "Important information:"
    echo "  • VMs using TrueNAS storage will lose disk access"
    echo "  • Data on TrueNAS will NOT be deleted"
    echo "  • A backup will be created before removal"
    echo "  • You can rollback using the backup if needed"
    echo

    read -rp "Are you sure you want to uninstall? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Uninstallation cancelled"
        return 0
    fi

    echo
    read -rp "Also remove storage configuration from $STORAGE_CFG? (y/N): " remove_config_choice

    local remove_config=false
    [[ "$remove_config_choice" =~ ^[Yy] ]] && remove_config=true

    if uninstall_plugin "$remove_config"; then
        success "Uninstallation complete"
    else
        error "Uninstallation failed"
    fi
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"

    # Detect if stdin is not a TTY (piped from curl/wget) and redirect to terminal
    if [[ ! -t 0 ]] && [[ "$NON_INTERACTIVE" != "true" ]]; then
        # Try to reconnect stdin to the controlling terminal
        if [[ -c /dev/tty ]] && ( : </dev/tty ) 2>/dev/null; then
            # Test if /dev/tty is actually connected to a terminal
            if [[ -t /dev/tty ]] 2>/dev/null || ( [[ -c /dev/tty ]] && tty -s </dev/tty 2>/dev/null ); then
                # Successfully can use /dev/tty for interactive input
                exec 0</dev/tty
                log "INFO" "Redirected stdin from pipe to /dev/tty for interactive mode"
            else
                # /dev/tty exists but is not usable for interactive input
                echo
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  TrueNAS Plugin Installer - Interactive Mode Not Available"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo
                echo "This installer was run in a non-interactive context (e.g., via SSH"
                echo "without a pseudo-terminal) and cannot access your terminal for prompts."
                echo
                echo "Please choose one of these methods instead:"
                echo
                echo "  ${COLOR_GREEN}1. SSH to Proxmox, then run installer (Recommended)${COLOR_RESET}"
                echo "     ssh root@your-proxmox-host"
                echo "     bash <(curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh)"
                echo
                echo "  ${COLOR_GREEN}2. Download and Run${COLOR_RESET}"
                echo "     wget https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh"
                echo "     chmod +x install.sh"
                echo "     ./install.sh"
                echo
                echo "  ${COLOR_YELLOW}3. Non-Interactive (For Automation)${COLOR_RESET}"
                echo "     curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash -s -- --non-interactive"
                echo
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo
                exit $EXIT_ERROR
            fi
        else
            # Cannot redirect - show helpful error
            echo
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  TrueNAS Plugin Installer - Interactive Mode Not Available"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo
            echo "This installer was piped from curl/wget but cannot access your"
            echo "terminal for interactive prompts."
            echo
            echo "Please choose one of these methods instead:"
            echo
            echo "  ${COLOR_GREEN}1. SSH to Proxmox, then run installer (Recommended)${COLOR_RESET}"
            echo "     ssh root@your-proxmox-host"
            echo "     bash <(curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh)"
            echo
            echo "  ${COLOR_GREEN}2. Download and Run${COLOR_RESET}"
            echo "     wget https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh"
            echo "     chmod +x install.sh"
            echo "     ./install.sh"
            echo
            echo "  ${COLOR_YELLOW}3. Non-Interactive (For Automation)${COLOR_RESET}"
            echo "     curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/alpha/install.sh | bash -s -- --non-interactive"
            echo
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo
            exit $EXIT_ERROR
        fi
    fi

    # Initialize logging
    init_logging

    # Clean up any orphaned processes from previous runs
    # This prevents accumulation of zombie spinners
    pkill -f "bash.*install\.sh.*while" 2>/dev/null || true
    pkill -f "sleep 0\.1" 2>/dev/null || true

    # Perform checks (with banner for non-interactive mode only)
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        print_banner
    fi

    info "Checking system requirements..."
    check_root
    check_dependencies
    success "System requirements satisfied"

    # Main menu loop - re-detect state after certain operations
    while true; do
        # Get current installation state
        local install_state
        install_state=$(get_install_state)

        if [[ "$install_state" == "not_installed" ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                # Non-interactive mode: install latest version
                info "Non-interactive mode: Installing latest version..."
                perform_installation "latest"
                exit $?
            else
                # Interactive mode: show menu (menu will handle banner and screen clearing)
                menu_not_installed
            fi
        else
            # Plugin is installed
            local current_version="${install_state#installed:}"

            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                # Non-interactive mode: check for updates and install if available
                info "Non-interactive mode: Checking for updates..."
                if latest_version=$(check_for_updates "$current_version" 2>/dev/null); then
                    info "Update available: v${latest_version}"
                    perform_installation "latest"
                    exit $?
                else
                    success "Already on latest version"
                    exit 0
                fi
            else
                # Interactive mode: show menu (menu will handle banner and screen clearing)
                menu_installed "$current_version"
                # If menu returns, loop back to re-detect state
            fi
        fi
    done

    log "INFO" "Installer completed successfully"
}

# Run main function
main "$@"

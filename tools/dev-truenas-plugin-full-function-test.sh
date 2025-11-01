#!/usr/bin/env bash
#
# TrueNAS Plugin Comprehensive Test Suite
# Tests all plugin functions with structured output
#
# Test Phases:
#   1. Pre-flight Cleanup - Remove orphaned resources
#   2. Disk Allocation - Test disk creation with multiple sizes (1GB, 10GB, 32GB, 100GB)
#   3. TrueNAS Size Verification - Verify disk sizes match on TrueNAS backend
#   4. Disk Deletion - Test VM and disk deletion with cleanup verification
#   5. Clone & Snapshot - Test VM cloning, snapshots, and deletion
#   6. Disk Resize - Test expanding disk from 10GB to 20GB
#   7. Concurrent Operations - Test parallel disk allocations and deletions
#   8. Performance - Benchmark disk allocation and deletion timing
#   9. Multiple Disks - Test VMs with multiple disk attachments
#  10. EFI VM Creation - Test VM creation with EFI BIOS and EFI disk
#  11. Live Migration - Test online VM migration between cluster nodes (cluster only)
#  12. Offline Migration - Test offline VM migration between cluster nodes (cluster only)
#  13. Online Backup - Test backup of running VM (requires --backup-store)
#  14. Offline Backup - Test backup of stopped VM (requires --backup-store)
#  15. Cross-Node Clone (Online) - Test cloning running VM to different node (cluster only)
#  16. Cross-Node Clone (Offline) - Test cloning stopped VM to different node (cluster only)
#
# Performance Summary:
#   After all tests complete, a summary table displays average, min, and max times
#   for each operation type (disk allocation, deletion, clone, migration, backup, etc.)
#
# Usage: ./dev-truenas-plugin-full-function-test.sh [STORAGE_ID] [VMID_START] [OPTIONS]
#
# Arguments:
#   STORAGE_ID    - TrueNAS storage ID (default: tnscale)
#   VMID_START    - Starting VMID for test VMs (default: 9001)
#
# Options:
#   --backup-store STORAGE - Backup storage ID for backup tests (optional)
#                            If not specified, backup tests (Phases 13-14) will be skipped
#
# Examples:
#   ./dev-truenas-plugin-full-function-test.sh tnscale 9001
#   ./dev-truenas-plugin-full-function-test.sh tnscale 9001 --backup-store pbs
#
# Cluster Detection:
#   The script automatically detects if running in a cluster environment.
#   If cluster is detected and other nodes are available, migration and cross-node
#   clone tests (Phases 11, 12, 15, 16) will be executed. Otherwise, they are skipped.
#
# NOTE: This script must be run directly on a Proxmox VE node.
#       It will auto-detect the local node name.
#       ⚠️  WARNING: FOR DEVELOPMENT USE ONLY - NOT FOR PRODUCTION!
#       ⚠️  This script creates and destroys VMs in the specified VMID range.
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Parse command-line arguments
STORAGE_ID="${1:-tnscale}"
VMID_START="${2:-9001}"
BACKUP_STORE=""
START_PHASE=1

# Process optional arguments
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --backup-store)
            BACKUP_STORE="$2"
            shift 2
            ;;
        --phase)
            START_PHASE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [STORAGE_ID] [VMID_START] [--backup-store BACKUP_STORAGE] [--phase PHASE_NUM]"
            exit 1
            ;;
    esac
done

NODE=$(hostname)
VMID_END=$((VMID_START + 30))  # Increased range for new tests
TEST_SIZES=(1 10 32 100)  # GB sizes to test

# Clone/Snapshot test VMIDs (at end of range)
CLONE_BASE_VMID=$((VMID_START + 20))
CLONE_VMID=$((CLONE_BASE_VMID + 1))

# Cluster detection variables (detection happens after helper functions are defined)
IS_CLUSTER=0
CLUSTER_NODES=()
TARGET_NODE=""

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="test-results-${TIMESTAMP}.log"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timing constants (in seconds)
readonly API_SETTLE_TIME=1        # Wait for API operations to settle
readonly DELETION_WAIT=1          # Wait after VM deletion to verify cleanup
readonly DELETION_VERIFY_SLEEP=2  # Initial wait before verifying deletions
readonly DISK_ATTACH_WAIT=1       # Wait after disk attachment
readonly DELETION_MAX_RETRIES=10  # Max attempts to verify VM deletion

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Timing
START_TIME=$(date +%s)

# Test results array
declare -a TEST_RESULTS

# Performance tracking arrays
declare -A PERF_TIMINGS  # operation_type -> "time1 time2 time3..."
declare -A PERF_COUNTS   # operation_type -> count

# Track timing for an operation
track_timing() {
    local operation="$1"
    local duration="$2"

    if [[ -z "${PERF_TIMINGS[$operation]:-}" ]]; then
        PERF_TIMINGS[$operation]="$duration"
        PERF_COUNTS[$operation]=1
    else
        PERF_TIMINGS[$operation]="${PERF_TIMINGS[$operation]} $duration"
        PERF_COUNTS[$operation]=$((PERF_COUNTS[$operation] + 1))
    fi
}

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

# Get storage configuration from storage.cfg
# Returns: "api_host|api_key|dataset"
get_storage_config() {
    local storage_id="$1"
    local config_file="/etc/pve/storage.cfg"

    local api_host api_key dataset
    api_host=$(grep -A 20 "^truenasplugin: $storage_id" "$config_file" | grep "api_host" | awk '{print $2}' | head -1)
    api_key=$(grep -A 20 "^truenasplugin: $storage_id" "$config_file" | grep "api_key" | awk '{print $2}' | head -1)
    dataset=$(grep -A 20 "^truenasplugin: $storage_id" "$config_file" | grep "dataset" | awk '{print $2}' | head -1)

    echo "$api_host|$api_key|$dataset"
}

# Parse VM node from cluster JSON
# Args: $1 = cluster JSON, $2 = VMID
# Returns: node name or empty string
parse_vm_node_from_json() {
    local cluster_json="$1"
    local vmid="$2"
    echo "$cluster_json" | grep -o "{[^}]*\"vmid\"[^}]*:$vmid[^}]*}" | grep -o "\"node\":\"[^\"]*\"" | cut -d'"' -f4 || echo ""
}

# Wait for VM deletions to complete (handles asynchronous pvesh delete)
# Args: $1 = vmid_start, $2 = vmid_end, $3 = max_retries (optional, defaults to DELETION_MAX_RETRIES)
wait_for_vm_deletion() {
    local vmid_start="$1"
    local vmid_end="$2"
    local max_retries="${3:-$DELETION_MAX_RETRIES}"

    log_info "Waiting for deletions to complete..."
    sleep $DELETION_VERIFY_SLEEP

    local retry_count=0
    while [[ $retry_count -lt $max_retries ]]; do
        local remaining_vms
        remaining_vms=$(timeout 30 pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo "[]")
        local found_any=0

        for vmid in $(seq "$vmid_start" "$vmid_end"); do
            if echo "$remaining_vms" | grep -q "\"vmid\":$vmid"; then
                found_any=1
                break
            fi
        done

        if [[ $found_any -eq 0 ]]; then
            log_success "All VMs successfully deleted"
            return 0
        fi

        log_info "Some VMs still exist, waiting... (attempt $((retry_count + 1))/$max_retries)"
        sleep $DELETION_WAIT
        retry_count=$((retry_count + 1))
    done

    log_warning "Some VMs may still exist after cleanup timeout"
    return 1
}

# ============================================================================
# Cluster Detection (runs after helper functions are available)
# ============================================================================

# Detect if this is a cluster
if pvesh get /cluster/status --output-format=json 2>/dev/null | grep -q '"type":"cluster"'; then
    IS_CLUSTER=1

    # Get list of online nodes (excluding current node)
    mapfile -t CLUSTER_NODES < <(pvesh get /nodes --output-format=json 2>/dev/null | \
        grep -o '"node":"[^"]*"' | cut -d'"' -f4 | grep -v "^$NODE$" || echo "")

    if [[ ${#CLUSTER_NODES[@]} -gt 0 ]]; then
        TARGET_NODE="${CLUSTER_NODES[0]}"
    else
        IS_CLUSTER=0
    fi
fi

# ============================================================================
# Phase 1: Cleanup Functions
# ============================================================================

cleanup_test_vms() {
    local vmid_start="$1"
    local vmid_end="$2"

    log_info "Pre-flight cleanup: checking for orphaned resources in VMID range $vmid_start-$vmid_end (cluster-wide)..."

    local cleaned=0

    # Query cluster resources once with timeout
    log_info "Querying cluster resources..."
    local cluster_vms
    cluster_vms=$(timeout 30 pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo "[]")

    # Parse all VMIDs and nodes in our range from the single query
    declare -A vm_nodes  # Associate array: vmid -> node
    local vm_count=0
    for vmid in $(seq "$vmid_start" "$vmid_end"); do
        local node
        node=$(parse_vm_node_from_json "$cluster_vms" "$vmid")
        if [[ -n "$node" ]]; then
            vm_nodes[$vmid]="$node"
            vm_count=$((vm_count + 1))
        fi
    done

    # Query storage once with timeout
    log_info "Querying storage for all disks..."
    local all_disks
    all_disks=$(timeout 30 pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 || echo "")

    # Delete existing VMs
    if [[ $vm_count -gt 0 ]]; then
        log_info "Found $vm_count VMs to clean up"
        for vmid in "${!vm_nodes[@]}"; do
            local node="${vm_nodes[$vmid]}"
            log_warning "Deleting VM $vmid on node $node..."
            timeout 60 pvesh delete "/nodes/$node/qemu/$vmid" >/dev/null 2>&1 || true
            cleaned=$((cleaned + 1))
            sleep $DISK_ATTACH_WAIT
        done
    else
        log_success "No VMs found in range"
    fi

    # Check for orphaned disks in storage and delete the VMs that own them
    if [[ -n "$all_disks" ]]; then
        log_info "Checking for orphaned disks..."
        declare -A orphaned_vms  # Track unique VMIDs with orphaned disks

        while read -r line; do
            local volid
            volid=$(echo "$line" | awk '{print $1}')

            # Skip the weight zvol used for target visibility
            if [[ "$volid" == *"pve-plugin-weight"* ]]; then
                continue
            fi

            # Check if disk belongs to our VMID range and extract VMID
            for vmid in $(seq "$vmid_start" "$vmid_end"); do
                if [[ "$volid" == *"vm-${vmid}-"* ]]; then
                    orphaned_vms[$vmid]=1
                    break
                fi
            done
        done <<< "$all_disks"

        # Delete VMs with orphaned disks
        for vmid in "${!orphaned_vms[@]}"; do
            log_warning "Found orphaned disk(s) for VM $vmid, attempting cleanup..."

            # Try to find and delete VM from any node
            local vm_node
            vm_node=$(parse_vm_node_from_json "$cluster_vms" "$vmid")

            if [[ -n "$vm_node" ]]; then
                log_warning "Deleting VM $vmid from node $vm_node..."
                timeout 60 pvesh delete "/nodes/$vm_node/qemu/$vmid" >/dev/null 2>&1 || true
                cleaned=$((cleaned + 1))
            else
                # VM config doesn't exist, try to free disks directly
                log_warning "VM $vmid config not found, removing disks directly..."
                while read -r line; do
                    local volid
                    volid=$(echo "$line" | awk '{print $1}')
                    if [[ "$volid" == *"vm-${vmid}-"* ]] && [[ "$volid" != *"pve-plugin-weight"* ]]; then
                        timeout 60 pvesm free "$volid" >/dev/null 2>&1 || true
                        cleaned=$((cleaned + 1))
                    fi
                done <<< "$all_disks"
            fi
            sleep $DISK_ATTACH_WAIT
        done
    fi

    if [[ $cleaned -gt 0 ]]; then
        log_success "Cleaned up $cleaned orphaned resources"
        wait_for_vm_deletion "$vmid_start" "$vmid_end"
    else
        log_success "No orphaned resources found"
    fi
}

# ============================================================================
# Phase 2: Disk Allocation Tests
# ============================================================================

test_disk_allocation() {
    local size_gb="$1"
    local vmid="$2"
    local test_num="$3"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Allocate ${size_gb}GB disk (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)
    local expected_bytes=$((size_gb * 1024 * 1024 * 1024))

    # Create VM
    if ! pvesh create /nodes/$NODE/qemu -vmid $vmid -name "test-alloc-${size_gb}gb" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid $vmid \
        -filename "vm-$vmid-disk-0" \
        -size "${size_gb}G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if [[ -z "$volid" ]] || [[ "$volid" == *"error"* ]]; then
        log_error "Failed to allocate disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Verify size
    local actual_size
    actual_size=$(pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1 || echo "0")

    local duration=$(($(date +%s) - start_time))

    if [[ "$actual_size" == "$expected_bytes" ]]; then
        log_success "Disk allocated: $volid ($actual_size bytes) in ${duration}s"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("PASS: $test_name")
        track_timing "disk_allocation" "$duration"
        return 0
    else
        log_error "Size mismatch: expected $expected_bytes, got $actual_size"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
}

# ============================================================================
# Phase 3: TrueNAS Size Verification Tests
# ============================================================================

test_truenas_size_verification() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Verify size on TrueNAS (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Get TrueNAS API credentials from storage.cfg
    local config api_host api_key dataset
    config=$(get_storage_config "$STORAGE_ID")
    IFS='|' read -r api_host api_key dataset <<< "$config"

    if [[ -z "$api_host" ]] || [[ -z "$api_key" ]] || [[ -z "$dataset" ]]; then
        log_error "Failed to read storage configuration"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Get size from Proxmox
    local pvesm_size
    pvesm_size=$(timeout 30 pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1 || echo "0")

    if [[ "$pvesm_size" == "0" ]]; then
        log_error "No disk found for VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Get size from TrueNAS - URL encode the path manually
    local dataset_path="${dataset}/vm-${vmid}-disk-0"
    local encoded_path
    # Simple URL encoding: replace / with %2F
    encoded_path=$(echo -n "$dataset_path" | sed 's|/|%2F|g')

    local truenas_size
    local api_response
    api_response=$(timeout 30 curl -sk -H "Authorization: Bearer $api_key" \
        "https://$api_host/api/v2.0/pool/dataset/id/$encoded_path" 2>/dev/null || echo "{}")

    # Parse volsize.parsed from JSON without jq
    # TrueNAS returns volsize as an object with a "parsed" field containing the numeric value
    truenas_size=$(echo "$api_response" | grep -A 2 "\"volsize\"" | grep "\"parsed\"" | awk -F: '{print $2}' | tr -d ' ,' | head -1 || echo "0")

    if [[ "$truenas_size" == "0" ]]; then
        log_error "Failed to get zvol size from TrueNAS"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local duration=$(($(date +%s) - start_time))

    if [[ "$pvesm_size" == "$truenas_size" ]]; then
        log_success "Sizes match: Proxmox=$pvesm_size, TrueNAS=$truenas_size (${duration}s)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("PASS: $test_name")
        return 0
    else
        log_error "Size mismatch: Proxmox=$pvesm_size, TrueNAS=$truenas_size"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
}

# ============================================================================
# Phase 4: Disk Deletion Tests
# ============================================================================

test_disk_deletion() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Delete disk and verify cleanup (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Check disk exists
    local disks_before
    disks_before=$(pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 || echo "")
    if [[ -z "$disks_before" ]]; then
        log_error "No disks found for VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local volid
    volid=$(echo "$disks_before" | awk '{print $1}' | head -1)

    # Attach disk to VM config so it will be automatically removed
    if ! qm set $vmid -scsi0 "$volid" >/dev/null 2>&1; then
        log_warning "Could not attach disk (might already be attached)"
    fi

    # Delete VM and time only the deletion operation
    local delete_start=$(date +%s)
    if ! pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1; then
        log_error "Failed to delete VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
    local delete_duration=$(($(date +%s) - delete_start))

    sleep $DELETION_WAIT

    # Verify cleanup
    local disks_after
    disks_after=$(pvesm list "$STORAGE_ID" --vmid $vmid 2>/dev/null | tail -n +2 || echo "")

    local duration=$(($(date +%s) - start_time))

    if [[ -z "$disks_after" ]]; then
        log_success "VM and disk deleted, cleanup verified (${duration}s, actual deletion: ${delete_duration}s)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("PASS: $test_name")
        track_timing "disk_deletion" "$delete_duration"
        return 0
    else
        log_error "Orphaned disks remain: $disks_after"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi
}

# ============================================================================
# Phase 5: Clone and Snapshot Tests
# ============================================================================

test_create_base_vm_for_clone() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create base VM for cloning tests (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Create VM
    if ! pvesh create /nodes/$NODE/qemu -vmid $vmid -name "test-clone-base" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create base VM $vmid"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid $vmid \
        -filename "vm-$vmid-disk-0" \
        -size "10G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if [[ -z "$volid" ]] || [[ "$volid" == *"error"* ]]; then
        log_error "Failed to allocate disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Attach disk to VM
    if ! qm set $vmid -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk to VM"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local duration=$(($(date +%s) - start_time))
    log_success "Base VM created with disk $volid (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

test_create_snapshot() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create snapshot (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)
    local snapshot_name="test-snapshot-$(date +%s)"

    # Create snapshot
    if ! qm snapshot $vmid "$snapshot_name" --description "Test snapshot" >/dev/null 2>&1; then
        log_error "Failed to create snapshot"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Verify snapshot exists
    local snaplist
    snaplist=$(qm listsnapshot $vmid 2>/dev/null | grep "$snapshot_name" || echo "")

    if [[ -z "$snaplist" ]]; then
        log_error "Snapshot not found in list"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local duration=$(($(date +%s) - start_time))
    log_success "Snapshot '$snapshot_name' created and verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")

    # Store snapshot name for later tests
    echo "$snapshot_name" > "/tmp/test-snapshot-name-${vmid}.txt"
    return 0
}

test_full_clone() {
    local base_vmid="$1"
    local clone_vmid="$2"
    local test_num="$3"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Create full clone (VMID $base_vmid → $clone_vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Create full clone
    if ! qm clone $base_vmid $clone_vmid --name "test-full-clone" --full --storage "$STORAGE_ID" >/dev/null 2>&1; then
        log_error "Failed to create full clone"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Verify clone exists
    if ! pvesh get "/nodes/$NODE/qemu/$clone_vmid" >/dev/null 2>&1; then
        log_error "Clone VM does not exist"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Verify clone has disk
    local clone_disks
    clone_disks=$(pvesm list "$STORAGE_ID" --vmid $clone_vmid 2>/dev/null | tail -n +2 || echo "")

    if [[ -z "$clone_disks" ]]; then
        log_error "Clone VM has no disk"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    local disk_size
    disk_size=$(echo "$clone_disks" | awk '{print $4}' | head -1)

    local duration=$(($(date +%s) - start_time))
    log_success "Full clone created (disk size: $disk_size bytes) (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    track_timing "clone_operation" "$duration"
    return 0
}

test_delete_snapshot() {
    local vmid="$1"
    local test_num="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local test_name="Delete snapshot (VMID $vmid)"

    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"

    local start_time=$(date +%s)

    # Read snapshot name
    local snapshot_name
    if [[ -f "/tmp/test-snapshot-name-${vmid}.txt" ]]; then
        snapshot_name=$(cat "/tmp/test-snapshot-name-${vmid}.txt")
    else
        log_error "Snapshot name not found"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Delete snapshot
    if ! qm delsnapshot $vmid "$snapshot_name" >/dev/null 2>&1; then
        log_error "Failed to delete snapshot"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Verify snapshot is gone
    local snaplist
    snaplist=$(qm listsnapshot $vmid 2>/dev/null | grep "$snapshot_name" || echo "")

    if [[ -n "$snaplist" ]]; then
        log_error "Snapshot still exists after deletion"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name")
        return 1
    fi

    # Cleanup temp file
    rm -f "/tmp/test-snapshot-name-${vmid}.txt"

    local duration=$(($(date +%s) - start_time))
    log_success "Snapshot deleted and cleanup verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 6: Disk Resize
# ============================================================================

test_disk_resize() {
    local vmid=$1
    local test_num=$2
    local test_name="Disk Resize (10GB → 20GB)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Create VM with 10GB disk
    log_info "Creating VM with 10GB disk"
    if ! qm create "$vmid" -name "test-resize-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "10G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    log_success "Created VM with disk: $volid"
    sleep $API_SETTLE_TIME

    # Verify original size
    local orig_size
    orig_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1)
    log_info "Original size: $orig_size bytes (10GB = 10737418240)"

    # Resize disk to 20GB
    log_info "Resizing disk to 20GB"
    if ! qm resize "$vmid" scsi0 "20G" >/dev/null 2>&1; then
        log_error "Resize command failed"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Resize failed")
        return 1
    fi

    sleep $DELETION_WAIT

    # Verify new size
    local new_size
    new_size=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | awk '{print $4}' | head -1)
    local expected=21474836480

    log_info "New size: $new_size bytes (expected: $expected)"

    if [[ "$new_size" != "$expected" ]]; then
        log_error "Size mismatch: got $new_size, expected $expected"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Size verification failed")
        return 1
    fi

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    wait_for_vm_deletion "$vmid" "$vmid" 5

    local duration=$(($(date +%s) - start_time))
    log_success "Disk resize verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 7: Concurrent Operations
# ============================================================================

test_concurrent_operations() {
    local base_vmid=$1
    local test_num=$2
    local test_name="Concurrent Operations (2 VMs in parallel)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Initial cleanup
    for i in {0..1}; do
        local vmid_cleanup=$((base_vmid + i))
        pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
    done
    sleep $API_SETTLE_TIME

    # Test concurrent allocations
    log_info "Allocating 2 VMs in parallel"
    local pids=()
    local failed=0

    for i in {0..1}; do
        local vmid=$((base_vmid + i))
        (
            # Stagger start
            sleep $(echo "scale=1; $i * 0.5" | bc)

            # Create VM
            qm create "$vmid" -name "test-concurrent-$i" -memory 512 >/dev/null 2>&1 || exit 1
            sleep $DELETION_WAIT

            # Allocate disk with retries
            local volid=""
            for attempt in {1..5}; do
                local output
                output=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
                    -vmid "$vmid" \
                    -filename "vm-${vmid}-disk-0" \
                    -size "5G" \
                    --output-format=json 2>&1)

                volid=$(echo "$output" | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

                [[ -n "$volid" && "$volid" =~ ^$STORAGE_ID:vol- ]] && break
                volid=""
                sleep 5
            done

            [[ -n "$volid" ]] || exit 1

            # Attach disk
            qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1 || exit 1

        ) &
        pids+=($!)
    done

    # Wait for completions
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed VM(s) failed to create"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Concurrent allocation failed")
        return 1
    fi

    log_success "All 2 VMs created successfully"
    sleep $DELETION_WAIT

    # Verify disks
    log_info "Verifying disks exist"
    local disk_count
    disk_count=$(pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 | { grep -E "vm-($base_vmid|$((base_vmid+1)))" || true; } | wc -l)

    if [[ $disk_count -ne 2 ]]; then
        log_error "Expected 2 disks, found $disk_count"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk verification failed")
        return 1
    fi

    log_success "All disks verified"

    # Test concurrent deletions
    log_info "Deleting 2 VMs in parallel"
    pids=()
    failed=0

    for i in {0..1}; do
        local vmid=$((base_vmid + i))
        (
            pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed VM(s) failed to delete"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Concurrent deletion failed")
        return 1
    fi

    log_success "All 2 VMs deleted successfully"

    # Wait for deletions to complete and verify cleanup
    wait_for_vm_deletion "$base_vmid" "$((base_vmid + 1))" 5
    local remaining
    remaining=$(pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 | { grep -E "vm-($base_vmid|$((base_vmid+1)))" || true; } | wc -l)

    if [[ $remaining -ne 0 ]]; then
        log_error "$remaining disk(s) remain after deletion"
        for i in {0..1}; do
            local vmid_cleanup=$((base_vmid + i))
            pvesh delete "/nodes/$NODE/qemu/$vmid_cleanup" >/dev/null 2>&1 || true
        done
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Cleanup verification failed")
        return 1
    fi

    log_success "All disks cleaned up"

    local duration=$(($(date +%s) - start_time))
    log_success "Concurrent operations verified (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 8: Performance
# ============================================================================

test_performance() {
    local base_vmid=$1
    local test_num=$2
    local test_name="Performance Benchmarks"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    for i in {0..2}; do
        pvesh delete "/nodes/$NODE/qemu/$((base_vmid + i))" >/dev/null 2>&1 || true
    done
    sleep $API_SETTLE_TIME

    # Test 1: 5GB allocation
    log_info "Timing 5GB disk allocation"
    local vmid=$base_vmid
    qm create "$vmid" -name "perf-test-5g" -memory 512 >/dev/null 2>&1

    local alloc_start=$(date +%s%3N)
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)
    local alloc_end=$(date +%s%3N)
    local elapsed=$((alloc_end - alloc_start))

    qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1
    log_success "5GB allocation: ${elapsed}ms (threshold: <30s)"

    if [[ $elapsed -ge 30000 ]]; then
        log_warning "Allocation slower than expected (>30s)"
    fi

    sleep $API_SETTLE_TIME

    # Test 2: 20GB allocation
    log_info "Timing 20GB disk allocation"
    vmid=$((base_vmid + 1))
    qm create "$vmid" -name "perf-test-20g" -memory 512 >/dev/null 2>&1

    alloc_start=$(date +%s%3N)
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "20G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)
    alloc_end=$(date +%s%3N)
    elapsed=$((alloc_end - alloc_start))

    qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1
    log_success "20GB allocation: ${elapsed}ms (threshold: <60s)"

    if [[ $elapsed -ge 60000 ]]; then
        log_warning "Allocation slower than expected (>60s)"
    fi

    sleep $API_SETTLE_TIME

    # Test 3: Deletion performance
    log_info "Timing VM deletion"
    vmid=$base_vmid

    local del_start=$(date +%s%3N)
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    local del_end=$(date +%s%3N)
    elapsed=$((del_end - del_start))

    log_success "VM deletion: ${elapsed}ms (threshold: <15s)"

    if [[ $elapsed -ge 15000 ]]; then
        log_warning "Deletion slower than expected (>15s)"
    fi

    # Cleanup remaining
    for i in {0..2}; do
        pvesh delete "/nodes/$NODE/qemu/$((base_vmid + i))" >/dev/null 2>&1 || true
    done
    wait_for_vm_deletion "$base_vmid" "$((base_vmid + 2))" 5

    local duration=$(($(date +%s) - start_time))
    log_success "Performance benchmarks completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 9: Multiple Disks
# ============================================================================

test_multiple_disks() {
    local vmid=$1
    local test_num=$2
    local test_name="Multiple Disks (3 disks per VM)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create VM
    log_info "Creating VM"
    if ! qm create "$vmid" -name "test-multi-disk-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    # Allocate 3 disks
    log_info "Allocating 3 disks"
    for i in {0..2}; do
        local volid
        volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
            -vmid "$vmid" \
            -filename "vm-${vmid}-disk-${i}" \
            -size "5G" \
            --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

        if ! qm set "$vmid" -scsi${i} "$volid" >/dev/null 2>&1; then
            log_error "Failed to attach disk $i"
            pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
            FAILED_TESTS=$((FAILED_TESTS + 1))
            TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
            return 1
        fi

        sleep $DISK_ATTACH_WAIT
    done

    log_success "All 3 disks allocated"
    sleep $API_SETTLE_TIME

    # Verify disks in VM config
    log_info "Verifying disks in VM config"
    local config
    config=$(qm config "$vmid")
    local disk_count=0

    for i in {0..2}; do
        if echo "$config" | grep -q "^scsi${i}:"; then
            disk_count=$((disk_count + 1))
        fi
    done

    if [[ $disk_count -ne 3 ]]; then
        log_error "Expected 3 disks in config, found $disk_count"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Config verification failed")
        return 1
    fi

    log_success "All disks in VM config"

    # Verify disks in storage
    log_info "Verifying disks in storage"
    local storage_disk_count
    storage_disk_count=$(pvesm list "$STORAGE_ID" --vmid "$vmid" 2>/dev/null | tail -n +2 | wc -l)

    if [[ $storage_disk_count -ne 3 ]]; then
        log_error "Expected 3 disks in storage, found $storage_disk_count"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Storage verification failed")
        return 1
    fi

    log_success "All disks in storage"

    # Delete VM and verify all disks deleted
    log_info "Verifying all disks deleted with VM"
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    wait_for_vm_deletion "$vmid" "$vmid" 5

    local remaining
    remaining=$(pvesm list "$STORAGE_ID" 2>/dev/null | tail -n +2 | { grep "vm-${vmid}-disk" || true; } | wc -l)

    if [[ $remaining -ne 0 ]]; then
        log_error "$remaining disk(s) not deleted"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Cleanup verification failed")
        return 1
    fi

    log_success "All disks deleted"

    local duration=$(($(date +%s) - start_time))
    log_success "Multiple disks test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 10: EFI VM Creation
# ============================================================================

test_efi_vm_creation() {
    local vmid=$1
    local test_num=$2
    local test_name="EFI VM Creation and Boot Configuration"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create EFI VM
    log_info "Creating VM with EFI BIOS"
    if ! qm create "$vmid" -name "test-efi-${vmid}" -memory 512 -bios ovmf >/dev/null 2>&1; then
        log_error "Failed to create EFI VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    # Allocate EFI disk on storage
    log_info "Allocating EFI boot disk"
    local efi_volid
    efi_volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "1M" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if [[ -z "$efi_volid" ]] || [[ "$efi_volid" == *"error"* ]]; then
        log_error "Failed to allocate EFI disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - EFI disk allocation failed")
        return 1
    fi

    # Configure EFI disk
    if ! qm set "$vmid" -efidisk0 "$efi_volid" >/dev/null 2>&1; then
        log_error "Failed to set EFI disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - EFI disk configuration failed")
        return 1
    fi

    # Allocate data disk
    log_info "Allocating data disk"
    local data_volid
    data_volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-1" \
        -size "10G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$vmid" -scsi0 "$data_volid" >/dev/null 2>&1; then
        log_error "Failed to attach data disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Data disk attachment failed")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Verify VM config
    log_info "Verifying EFI configuration"
    local config
    config=$(qm config "$vmid")

    if ! echo "$config" | grep -q "^bios: ovmf"; then
        log_error "BIOS not set to OVMF"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - BIOS verification failed")
        return 1
    fi

    if ! echo "$config" | grep -q "^efidisk0:"; then
        log_error "EFI disk not found in config"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - EFI disk verification failed")
        return 1
    fi

    log_success "EFI VM configured correctly"

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    wait_for_vm_deletion "$vmid" "$vmid" 5

    local duration=$(($(date +%s) - start_time))
    log_success "EFI VM test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    track_timing "efi_vm_creation" "$duration"
    return 0
}

# ============================================================================
# Phase 11: Live Migration
# ============================================================================

test_live_migration() {
    local vmid=$1
    local test_num=$2
    local test_name="Live Migration (Online)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    pvesh delete "/nodes/$TARGET_NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create VM
    log_info "Creating VM on $NODE"
    if ! qm create "$vmid" -name "test-migrate-live-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Start VM
    log_info "Starting VM"
    if ! qm start "$vmid" >/dev/null 2>&1; then
        log_error "Failed to start VM"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM start failed")
        return 1
    fi

    sleep 3

    # Migrate to target node
    log_info "Migrating VM from $NODE to $TARGET_NODE (live)"
    local migrate_start=$(date +%s)
    if ! qm migrate "$vmid" "$TARGET_NODE" --online >/dev/null 2>&1; then
        log_error "Failed to migrate to $TARGET_NODE"
        qm stop "$vmid" >/dev/null 2>&1 || true
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Migration to target failed")
        return 1
    fi
    local migrate_duration=$(($(date +%s) - migrate_start))

    sleep $API_SETTLE_TIME

    # Verify VM is on target node
    if ! pvesh get "/nodes/$TARGET_NODE/qemu/$vmid/status/current" >/dev/null 2>&1; then
        log_error "VM not found on $TARGET_NODE"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM not on target node")
        return 1
    fi

    log_success "VM migrated to $TARGET_NODE in ${migrate_duration}s"
    track_timing "live_migration" "$migrate_duration"

    # Migrate back to original node
    log_info "Migrating VM back from $TARGET_NODE to $NODE (live)"
    migrate_start=$(date +%s)
    if ! pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/migrate" -target "$NODE" -online 1 >/dev/null 2>&1; then
        log_error "Failed to migrate back to $NODE"
        pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/status/stop" >/dev/null 2>&1 || true
        pvesh delete "/nodes/$TARGET_NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Migration back failed")
        return 1
    fi
    migrate_duration=$(($(date +%s) - migrate_start))

    sleep $API_SETTLE_TIME

    log_success "VM migrated back to $NODE in ${migrate_duration}s"
    track_timing "live_migration" "$migrate_duration"

    # Stop and cleanup
    qm stop "$vmid" >/dev/null 2>&1 || true
    sleep 2
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    wait_for_vm_deletion "$vmid" "$vmid" 5

    local duration=$(($(date +%s) - start_time))
    log_success "Live migration test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 12: Offline Migration
# ============================================================================

test_offline_migration() {
    local vmid=$1
    local test_num=$2
    local test_name="Offline Migration"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    pvesh delete "/nodes/$TARGET_NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create VM
    log_info "Creating VM on $NODE"
    if ! qm create "$vmid" -name "test-migrate-offline-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Migrate to target node (offline)
    log_info "Migrating VM from $NODE to $TARGET_NODE (offline)"
    local migrate_start=$(date +%s)
    if ! qm migrate "$vmid" "$TARGET_NODE" >/dev/null 2>&1; then
        log_error "Failed to migrate to $TARGET_NODE"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Migration to target failed")
        return 1
    fi
    local migrate_duration=$(($(date +%s) - migrate_start))

    sleep $API_SETTLE_TIME

    # Verify VM is on target node
    if ! pvesh get "/nodes/$TARGET_NODE/qemu/$vmid/config" >/dev/null 2>&1; then
        log_error "VM not found on $TARGET_NODE"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM not on target node")
        return 1
    fi

    log_success "VM migrated to $TARGET_NODE in ${migrate_duration}s"
    track_timing "offline_migration" "$migrate_duration"

    # Migrate back to original node
    log_info "Migrating VM back from $TARGET_NODE to $NODE (offline)"
    migrate_start=$(date +%s)
    if ! pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/migrate" -target "$NODE" >/dev/null 2>&1; then
        log_error "Failed to migrate back to $NODE"
        pvesh delete "/nodes/$TARGET_NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Migration back failed")
        return 1
    fi
    migrate_duration=$(($(date +%s) - migrate_start))

    sleep $API_SETTLE_TIME

    log_success "VM migrated back to $NODE in ${migrate_duration}s"
    track_timing "offline_migration" "$migrate_duration"

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    wait_for_vm_deletion "$vmid" "$vmid" 5

    local duration=$(($(date +%s) - start_time))
    log_success "Offline migration test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 13: Online Backup
# ============================================================================

test_online_backup() {
    local vmid=$1
    local test_num=$2
    local test_name="Online Backup (Running VM)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create VM
    log_info "Creating VM"
    if ! qm create "$vmid" -name "test-backup-online-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Start VM
    log_info "Starting VM"
    if ! qm start "$vmid" >/dev/null 2>&1; then
        log_error "Failed to start VM"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM start failed")
        return 1
    fi

    sleep 3

    # Perform online backup
    log_info "Performing online backup to $BACKUP_STORE"
    local backup_start=$(date +%s)
    local backup_output
    backup_output=$(vzdump "$vmid" --storage "$BACKUP_STORE" --mode snapshot 2>&1)
    local backup_result=$?
    local backup_duration=$(($(date +%s) - backup_start))

    if [[ $backup_result -ne 0 ]]; then
        log_error "Backup failed: $backup_output"
        qm stop "$vmid" >/dev/null 2>&1 || true
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Backup operation failed")
        return 1
    fi

    log_success "Online backup completed in ${backup_duration}s"
    track_timing "online_backup" "$backup_duration"

    # Extract backup filename for cleanup
    local backup_file
    backup_file=$(echo "$backup_output" | grep -o "vzdump-qemu-${vmid}-[^']*\\.vma\\(\\.[^']*\\)\\?" | head -1)

    # Stop and cleanup VM
    qm stop "$vmid" >/dev/null 2>&1 || true
    sleep 2
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    wait_for_vm_deletion "$vmid" "$vmid" 5

    # Cleanup backup file
    if [[ -n "$backup_file" ]]; then
        log_info "Cleaning up backup file: $backup_file"
        pvesm free "$BACKUP_STORE:backup/$backup_file" >/dev/null 2>&1 || true
    fi

    local duration=$(($(date +%s) - start_time))
    log_success "Online backup test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 14: Offline Backup
# ============================================================================

test_offline_backup() {
    local vmid=$1
    local test_num=$2
    local test_name="Offline Backup (Stopped VM)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create VM
    log_info "Creating VM"
    if ! qm create "$vmid" -name "test-backup-offline-${vmid}" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM creation failed")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$vmid" \
        -filename "vm-${vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Perform offline backup (VM is stopped)
    log_info "Performing offline backup to $BACKUP_STORE"
    local backup_start=$(date +%s)
    local backup_output
    backup_output=$(vzdump "$vmid" --storage "$BACKUP_STORE" --mode stop 2>&1)
    local backup_result=$?
    local backup_duration=$(($(date +%s) - backup_start))

    if [[ $backup_result -ne 0 ]]; then
        log_error "Backup failed: $backup_output"
        pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Backup operation failed")
        return 1
    fi

    log_success "Offline backup completed in ${backup_duration}s"
    track_timing "offline_backup" "$backup_duration"

    # Extract backup filename for cleanup
    local backup_file
    backup_file=$(echo "$backup_output" | grep -o "vzdump-qemu-${vmid}-[^']*\\.vma\\(\\.[^']*\\)\\?" | head -1)

    # Cleanup VM
    pvesh delete "/nodes/$NODE/qemu/$vmid" >/dev/null 2>&1
    wait_for_vm_deletion "$vmid" "$vmid" 5

    # Cleanup backup file
    if [[ -n "$backup_file" ]]; then
        log_info "Cleaning up backup file: $backup_file"
        pvesm free "$BACKUP_STORE:backup/$backup_file" >/dev/null 2>&1 || true
    fi

    local duration=$(($(date +%s) - start_time))
    log_success "Offline backup test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 15: Cross-Node Clone (Online)
# ============================================================================

test_cross_node_clone_online() {
    local base_vmid=$1
    local clone_vmid=$2
    local test_num=$3
    local test_name="Cross-Node Clone (Online)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
    pvesh delete "/nodes/$TARGET_NODE/qemu/$clone_vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create base VM
    log_info "Creating base VM on $NODE"
    if ! qm create "$base_vmid" -name "test-xclone-online-base" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create base VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Base VM creation failed")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$base_vmid" \
        -filename "vm-${base_vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$base_vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Start VM
    log_info "Starting base VM"
    if ! qm start "$base_vmid" >/dev/null 2>&1; then
        log_error "Failed to start VM"
        pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - VM start failed")
        return 1
    fi

    sleep 3

    # Clone to target node
    log_info "Cloning VM from $NODE to $TARGET_NODE (online)"
    local clone_start=$(date +%s)
    if ! pvesh create "/nodes/$NODE/qemu/$base_vmid/clone" \
        -newid "$clone_vmid" \
        -name "test-xclone-online" \
        -target "$TARGET_NODE" \
        -full 1 \
        -storage "$STORAGE_ID" >/dev/null 2>&1; then
        log_error "Failed to clone to $TARGET_NODE"
        qm stop "$base_vmid" >/dev/null 2>&1 || true
        pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Clone operation failed")
        return 1
    fi
    local clone_duration=$(($(date +%s) - clone_start))

    sleep $API_SETTLE_TIME

    # Verify clone exists on target node
    if ! pvesh get "/nodes/$TARGET_NODE/qemu/$clone_vmid/config" >/dev/null 2>&1; then
        log_error "Clone not found on $TARGET_NODE"
        qm stop "$base_vmid" >/dev/null 2>&1 || true
        pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Clone verification failed")
        return 1
    fi

    log_success "Online cross-node clone completed in ${clone_duration}s"
    track_timing "cross_node_clone_online" "$clone_duration"

    # Cleanup
    qm stop "$base_vmid" >/dev/null 2>&1 || true
    sleep 2
    pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
    pvesh delete "/nodes/$TARGET_NODE/qemu/$clone_vmid" >/dev/null 2>&1 || true
    wait_for_vm_deletion "$base_vmid" "$base_vmid" 5

    local duration=$(($(date +%s) - start_time))
    log_success "Cross-node clone (online) test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Phase 16: Cross-Node Clone (Offline)
# ============================================================================

test_cross_node_clone_offline() {
    local base_vmid=$1
    local clone_vmid=$2
    local test_num=$3
    local test_name="Cross-Node Clone (Offline)"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "[$test_num] Testing: $test_name" | tee -a "$LOG_FILE"
    local start_time=$(date +%s)

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
    pvesh delete "/nodes/$TARGET_NODE/qemu/$clone_vmid" >/dev/null 2>&1 || true
    sleep $API_SETTLE_TIME

    # Create base VM
    log_info "Creating base VM on $NODE"
    if ! qm create "$base_vmid" -name "test-xclone-offline-base" -memory 512 >/dev/null 2>&1; then
        log_error "Failed to create base VM"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Base VM creation failed")
        return 1
    fi

    # Allocate disk
    local volid
    volid=$(pvesh create "/nodes/$NODE/storage/$STORAGE_ID/content" \
        -vmid "$base_vmid" \
        -filename "vm-${base_vmid}-disk-0" \
        -size "5G" \
        --output-format=json 2>&1 | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)

    if ! qm set "$base_vmid" -scsi0 "$volid" >/dev/null 2>&1; then
        log_error "Failed to attach disk"
        pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Disk attachment failed")
        return 1
    fi

    sleep $API_SETTLE_TIME

    # Clone to target node (offline)
    log_info "Cloning VM from $NODE to $TARGET_NODE (offline)"
    local clone_start=$(date +%s)
    if ! qm clone "$base_vmid" "$clone_vmid" \
        --name "test-xclone-offline" \
        --target "$TARGET_NODE" \
        --full \
        --storage "$STORAGE_ID" >/dev/null 2>&1; then
        log_error "Failed to clone to $TARGET_NODE"
        pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Clone operation failed")
        return 1
    fi
    local clone_duration=$(($(date +%s) - clone_start))

    sleep $API_SETTLE_TIME

    # Verify clone exists on target node
    if ! pvesh get "/nodes/$TARGET_NODE/qemu/$clone_vmid/config" >/dev/null 2>&1; then
        log_error "Clone not found on $TARGET_NODE"
        pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("FAIL: $test_name - Clone verification failed")
        return 1
    fi

    log_success "Offline cross-node clone completed in ${clone_duration}s"
    track_timing "cross_node_clone_offline" "$clone_duration"

    # Cleanup
    pvesh delete "/nodes/$NODE/qemu/$base_vmid" >/dev/null 2>&1 || true
    pvesh delete "/nodes/$TARGET_NODE/qemu/$clone_vmid" >/dev/null 2>&1 || true
    wait_for_vm_deletion "$base_vmid" "$base_vmid" 5

    local duration=$(($(date +%s) - start_time))
    log_success "Cross-node clone (offline) test completed (${duration}s)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TEST_RESULTS+=("PASS: $test_name")
    return 0
}

# ============================================================================
# Performance Summary Table
# ============================================================================

print_performance_summary() {
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PERFORMANCE SUMMARY" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    # Table header
    printf "%-30s %8s %8s %8s %8s\n" "Operation" "Count" "Avg (s)" "Min (s)" "Max (s)" | tee -a "$LOG_FILE"
    echo "────────────────────────────────────────────────────────────────────" | tee -a "$LOG_FILE"

    # Process each operation type
    for operation in "${!PERF_TIMINGS[@]}"; do
        local timings="${PERF_TIMINGS[$operation]}"
        local count="${PERF_COUNTS[$operation]}"

        # Calculate stats
        local sum=0
        local min=999999
        local max=0

        for time in $timings; do
            sum=$((sum + time))
            if [[ $time -lt $min ]]; then
                min=$time
            fi
            if [[ $time -gt $max ]]; then
                max=$time
            fi
        done

        local avg=$((sum / count))

        # Format operation name (replace underscores with spaces, capitalize)
        local op_name
        op_name=$(echo "$operation" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')

        printf "%-30s %8d %8d %8d %8d\n" "$op_name" "$count" "$avg" "$min" "$max" | tee -a "$LOG_FILE"
    done

    echo | tee -a "$LOG_FILE"
}

# ============================================================================
# Main Test Execution
# ============================================================================

main() {
    echo "╔════════════════════════════════════════════════════════════════════╗" | tee "$LOG_FILE"
    echo "║         TrueNAS Plugin Comprehensive Test Suite v1.0               ║" | tee -a "$LOG_FILE"
    echo "╚════════════════════════════════════════════════════════════════════╝" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    log_info "Configuration:"
    log_info "  Storage ID:    $STORAGE_ID"
    log_info "  Node:          $NODE"
    log_info "  VMID Range:    $VMID_START-$VMID_END"
    log_info "  Test Sizes:    ${TEST_SIZES[*]} GB"
    log_info "  Log File:      $LOG_FILE"
    if [[ $IS_CLUSTER -eq 1 ]]; then
        log_info "  Cluster Mode:  YES (target: $TARGET_NODE)"
    else
        log_info "  Cluster Mode:  NO (cluster tests will be skipped)"
    fi
    if [[ -n "$BACKUP_STORE" ]]; then
        log_info "  Backup Store:  $BACKUP_STORE"
    else
        log_info "  Backup Store:  NOT SET (backup tests will be skipped)"
    fi
    echo | tee -a "$LOG_FILE"

    # Phase 1: Cleanup
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 1: Pre-flight Cleanup" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    cleanup_test_vms "$VMID_START" "$VMID_END"
    echo | tee -a "$LOG_FILE"

    # Phase 2: Disk Allocation
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 2: Disk Allocation Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    local vmid=$VMID_START
    local test_num=1
    for size in "${TEST_SIZES[@]}"; do
        test_disk_allocation "$size" "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        vmid=$((vmid + 1))
        test_num=$((test_num + 1))
    done

    # Phase 3: TrueNAS Size Verification
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 3: TrueNAS Size Verification Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$VMID_START
    for size in "${TEST_SIZES[@]}"; do
        test_truenas_size_verification "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        vmid=$((vmid + 1))
        test_num=$((test_num + 1))
    done

    # Phase 4: Disk Deletion
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 4: Disk Deletion Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$VMID_START
    for size in "${TEST_SIZES[@]}"; do
        test_disk_deletion "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        vmid=$((vmid + 1))
        test_num=$((test_num + 1))
    done

    # Phase 5: Clone and Snapshot Tests
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 5: Clone and Snapshot Tests" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    # Create base VM for cloning
    test_create_base_vm_for_clone "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Create snapshot
    test_create_snapshot "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Create full clone
    test_full_clone "$CLONE_BASE_VMID" "$CLONE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Delete full clone
    test_disk_deletion "$CLONE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Delete snapshot
    test_delete_snapshot "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Delete base VM
    test_disk_deletion "$CLONE_BASE_VMID" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 6: Disk Resize
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 6: Disk Resize Test" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 10))
    test_disk_resize "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 7: Concurrent Operations
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 7: Concurrent Operations Test" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 11))
    test_concurrent_operations "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 8: Performance
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 8: Performance Benchmarks" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 13))
    test_performance "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 9: Multiple Disks
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 9: Multiple Disks Test" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 16))
    test_multiple_disks "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Phase 10: EFI VM Creation
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  PHASE 10: EFI VM Creation Test" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    vmid=$((VMID_START + 17))
    test_efi_vm_creation "$vmid" "$test_num"
    echo | tee -a "$LOG_FILE"
    test_num=$((test_num + 1))

    # Cluster-based tests (only if cluster detected)
    if [[ $IS_CLUSTER -eq 1 ]]; then
        # Phase 11: Live Migration
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo "  PHASE 11: Live Migration Test" | tee -a "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo | tee -a "$LOG_FILE"

        vmid=$((VMID_START + 18))
        test_live_migration "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        test_num=$((test_num + 1))

        # Phase 12: Offline Migration
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo "  PHASE 12: Offline Migration Test" | tee -a "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo | tee -a "$LOG_FILE"

        vmid=$((VMID_START + 19))
        test_offline_migration "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        test_num=$((test_num + 1))

        # Phase 15: Cross-Node Clone (Online)
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo "  PHASE 15: Cross-Node Clone (Online) Test" | tee -a "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo | tee -a "$LOG_FILE"

        vmid=$((VMID_START + 22))
        local clone_vmid=$((vmid + 1))
        test_cross_node_clone_online "$vmid" "$clone_vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        test_num=$((test_num + 1))

        # Phase 16: Cross-Node Clone (Offline)
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo "  PHASE 16: Cross-Node Clone (Offline) Test" | tee -a "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo | tee -a "$LOG_FILE"

        vmid=$((VMID_START + 24))
        clone_vmid=$((vmid + 1))
        test_cross_node_clone_offline "$vmid" "$clone_vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        test_num=$((test_num + 1))
    else
        log_info "Skipping cluster-based tests (Phases 11, 12, 15, 16) - not in a cluster or no target node available"
        echo | tee -a "$LOG_FILE"
    fi

    # Backup tests (only if backup storage specified)
    if [[ -n "$BACKUP_STORE" ]]; then
        # Phase 13: Online Backup
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo "  PHASE 13: Online Backup Test" | tee -a "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo | tee -a "$LOG_FILE"

        vmid=$((VMID_START + 20))
        test_online_backup "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        test_num=$((test_num + 1))

        # Phase 14: Offline Backup
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo "  PHASE 14: Offline Backup Test" | tee -a "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
        echo | tee -a "$LOG_FILE"

        vmid=$((VMID_START + 21))
        test_offline_backup "$vmid" "$test_num"
        echo | tee -a "$LOG_FILE"
        test_num=$((test_num + 1))
    else
        log_info "Skipping backup tests (Phases 13, 14) - no backup storage specified (use --backup-store)"
        echo | tee -a "$LOG_FILE"
    fi

    # Performance Summary
    print_performance_summary

    # Summary
    local end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))

    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  TEST SUMMARY" | tee -a "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    echo "Total Tests:  $TOTAL_TESTS" | tee -a "$LOG_FILE"
    echo "Passed:       $PASSED_TESTS ✓" | tee -a "$LOG_FILE"
    echo "Failed:       $FAILED_TESTS ✗" | tee -a "$LOG_FILE"
    echo "Duration:     ${total_duration}s" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    echo "Results:" | tee -a "$LOG_FILE"
    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$result" == PASS:* ]]; then
            echo "  ✓ ${result#PASS: }" | tee -a "$LOG_FILE"
        else
            echo "  ✗ ${result#FAIL: }" | tee -a "$LOG_FILE"
        fi
    done
    echo | tee -a "$LOG_FILE"
    echo "Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"

    if [[ $FAILED_TESTS -gt 0 ]]; then
        echo "Status: FAILED" | tee -a "$LOG_FILE"
        exit 1
    else
        echo "Status: ALL TESTS PASSED" | tee -a "$LOG_FILE"
        exit 0
    fi
}

# Run main function
main "$@"

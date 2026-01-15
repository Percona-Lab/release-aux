#!/bin/bash
set -euo pipefail

#############################################
# Repository Lock Manager
# 
# Manages locks for atomic repository push+sync operations
# Usage: repo-lock-manager.sh <repo-name> <acquire|release|status> [job-id] [build-num]
#############################################

REPO_NAME="${1:-}"
LOCK_OPERATION="${2:-}"

if [ -z "$REPO_NAME" ] || [ -z "$LOCK_OPERATION" ]; then
    echo "ERROR: Missing required parameters"
    echo "Usage: $0 <repo-name> <acquire|release|status> [job-identifier] [build-number]"
    exit 1
fi

#############################################
# Configuration
#############################################

# Repository base directory
REPO_BASE="/srv/repo-copy"

# Lock directory and metadata file
LOCK_DIR="${REPO_BASE}/${REPO_NAME}/.jenkins-publish-lock"
LOCK_INFO="${LOCK_DIR}/lock.info"

# Timeouts and intervals (can be overridden via environment)
MAX_WAIT_MINUTES=${MAX_WAIT_MINUTES:-20}
INITIAL_SLEEP=${INITIAL_SLEEP:-60}
SLEEP_INCREMENT=${SLEEP_INCREMENT:-30}
STALE_LOCK_MINUTES=${STALE_LOCK_MINUTES:-30}

# Job identification (from parameters or environment)
JOB_IDENTIFIER="${3:-${JOB_NAME:-unknown}}"
BUILD_NUM="${4:-${BUILD_NUMBER:-0}}"

#############################################
# Logging Functions
#############################################

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

#############################################
# Function: Acquire Lock
#############################################
acquire_lock() {
    local elapsed_seconds=0
    local sleep_duration=$INITIAL_SLEEP
    local max_wait_seconds=$((MAX_WAIT_MINUTES * 60))
    
    log_info "========================================"
    log_info "Acquiring lock for repository: ${REPO_NAME}"
    log_info "Job: ${JOB_IDENTIFIER} #${BUILD_NUM}"
    log_info "========================================"
    
    while true; do
        # Check if we've exceeded maximum wait time
        if [ $elapsed_seconds -ge $max_wait_seconds ]; then
            log_error "TIMEOUT: Failed to acquire lock after ${MAX_WAIT_MINUTES} minutes"
            log_error ""
            log_error "Current lock holder:"
            if [ -f "$LOCK_INFO" ]; then
                cat "$LOCK_INFO" >&2
            else
                log_error "Lock info file missing (lock directory exists but no metadata)"
            fi
            exit 1
        fi
        
        # Try to create lock directory atomically
        # mkdir is atomic in POSIX - only one process will succeed
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            # SUCCESS! We got the lock
            log_info "Lock acquired successfully"
            
            # Write lock metadata for debugging and monitoring
            cat > "$LOCK_INFO" <<EOF
job_identifier: ${JOB_IDENTIFIER}
build_number: ${BUILD_NUM}
hostname: $(hostname)
pid: $$
timestamp: $(date +%s)
human_time: $(date '+%Y-%m-%d %H:%M:%S')
EOF
            
            log_info "Lock metadata written"
            return 0
        fi
        
        # Lock directory already exists - check if it's stale
        if is_stale_lock; then
            log_warn "Detected stale lock - removing and retrying"
            remove_lock
            continue  # Try to acquire immediately
        fi
        
        # Lock is held by another active job - wait
        log_warn "Lock is currently held by another job"
        if [ -f "$LOCK_INFO" ]; then
            log_warn "Current lock holder:"
            cat "$LOCK_INFO" | while IFS= read -r line; do
                log_warn "  $line"
            done
        fi
        
        local elapsed_minutes=$((elapsed_seconds / 60))
        log_warn "Waiting ${sleep_duration} seconds before retry..."
        log_warn "Total wait time so far: ${elapsed_minutes} minutes (max: ${MAX_WAIT_MINUTES} minutes)"
        
        sleep $sleep_duration
        elapsed_seconds=$((elapsed_seconds + sleep_duration))
        
        # Exponential backoff - increase sleep duration for next iteration
        sleep_duration=$((sleep_duration + SLEEP_INCREMENT))
    done
}

#############################################
# Function: Check if Lock is Stale
#############################################
is_stale_lock() {
    # If lock directory exists but no metadata file, consider it stale
    if [ ! -f "$LOCK_INFO" ]; then
        log_warn "Lock directory exists but no metadata file - considering stale"
        return 0
    fi
    
    # Extract timestamp from lock metadata
    local lock_timestamp=$(grep "^timestamp:" "$LOCK_INFO" 2>/dev/null | cut -d' ' -f2)
    if [ -z "$lock_timestamp" ]; then
        log_warn "No timestamp in lock file - considering stale"
        return 0
    fi
    
    # Calculate lock age
    local current_timestamp=$(date +%s)
    local age_seconds=$((current_timestamp - lock_timestamp))
    local age_minutes=$((age_seconds / 60))
    local stale_seconds=$((STALE_LOCK_MINUTES * 60))
    
    # Check if lock exceeds stale threshold
    if [ $age_seconds -gt $stale_seconds ]; then
        log_warn "Lock age: ${age_minutes} minutes (threshold: ${STALE_LOCK_MINUTES} minutes)"
        return 0  # Is stale
    fi
    
    return 1  # Not stale
}

#############################################
# Function: Release Lock
#############################################
release_lock() {
    log_info "========================================"
    log_info "Releasing lock for repository: ${REPO_NAME}"
    log_info "Job: ${JOB_IDENTIFIER} #${BUILD_NUM}"
    log_info "========================================"
    
    # Check if lock exists
    if [ ! -d "$LOCK_DIR" ]; then
        log_warn "No lock to release (lock directory does not exist)"
        return 0
    fi
    
    # Verify ownership (optional - just for logging/debugging)
    if [ -f "$LOCK_INFO" ]; then
        local lock_job=$(grep "^job_identifier:" "$LOCK_INFO" 2>/dev/null | cut -d' ' -f2-)
        local lock_build=$(grep "^build_number:" "$LOCK_INFO" 2>/dev/null | cut -d' ' -f2-)
        
        log_info "Current lock holder: ${lock_job} #${lock_build}"
        log_info "This job: ${JOB_IDENTIFIER} #${BUILD_NUM}"
        
        # Warn if releasing lock held by different job
        # This might be okay if job was retried/rerun
        if [ "$lock_job" != "$JOB_IDENTIFIER" ]; then
            log_warn "Releasing lock held by different job: ${lock_job}"
            log_warn "This might be normal if job was retried or manually triggered"
        fi
    fi
    
    # Remove lock
    remove_lock
}

#############################################
# Function: Remove Lock (Internal)
#############################################
remove_lock() {
    if [ -d "$LOCK_DIR" ]; then
        # Remove metadata file first
        rm -f "$LOCK_INFO"
        
        # Remove lock directory
        # Use rmdir first (will fail if dir not empty, which is safer)
        # Fall back to rm -rf if needed
        rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
        
        log_info "Lock released successfully"
    fi
}

#############################################
# Function: Show Lock Status
#############################################
show_status() {
    log_info "========================================"
    log_info "Lock Status for repository: ${REPO_NAME}"
    log_info "========================================"
    
    # Check if lock directory exists
    if [ ! -d "$LOCK_DIR" ]; then
        log_info "Repository is UNLOCKED"
        return 0
    fi
    
    log_info "Repository is LOCKED"
    echo ""
    
    # Show lock details if metadata exists
    if [ -f "$LOCK_INFO" ]; then
        echo "Lock Details:"
        cat "$LOCK_INFO" | sed 's/^/  /'
        echo ""
        
        # Calculate and show lock age
        local lock_timestamp=$(grep "^timestamp:" "$LOCK_INFO" 2>/dev/null | cut -d' ' -f2)
        if [ -n "$lock_timestamp" ]; then
            local current_timestamp=$(date +%s)
            local age_seconds=$((current_timestamp - lock_timestamp))
            local age_minutes=$((age_seconds / 60))
            
            echo "Lock Age: ${age_minutes} minutes (${age_seconds} seconds)"
            
            # Warn if lock appears stale
            if [ $age_minutes -gt $STALE_LOCK_MINUTES ]; then
                log_warn "Lock appears STALE (older than ${STALE_LOCK_MINUTES} minutes)"
            fi
        fi
    else
        log_warn "Lock directory exists but metadata file is missing"
        log_warn "This indicates a corrupted lock state"
    fi
}

#############################################
# Main Execution
#############################################

case "$LOCK_OPERATION" in
    acquire)
        acquire_lock
        ;;
    release)
        release_lock
        ;;
    status)
        show_status
        ;;
    *)
        log_error "Invalid operation: $LOCK_OPERATION"
        echo "Valid operations: acquire, release, status"
        echo ""
        echo "Usage:"
        echo "  $0 <repo-name> acquire <job-identifier> <build-number>"
        echo "  $0 <repo-name> release <job-identifier> <build-number>"
        echo "  $0 <repo-name> status"
        exit 1
        ;;
esac

exit 0
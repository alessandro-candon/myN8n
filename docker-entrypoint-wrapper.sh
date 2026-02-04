#!/bin/sh
# =============================================================================
# n8n Startup Wrapper Script
# Handles GCS FUSE mount initialization, SQLite WAL checkpoint, and graceful shutdown
# =============================================================================

set -e

N8N_DATA_DIR="/home/node/.n8n"
DB_FILE="$N8N_DATA_DIR/database.sqlite"
MAX_WAIT=60
WAIT_INTERVAL=2
N8N_PID=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# =============================================================================
# SQLite WAL Checkpoint using Node.js sqlite3 package
# Flushes WAL data to main database file
# =============================================================================
checkpoint_sqlite_wal() {
    log "Attempting SQLite WAL checkpoint..."
    
    if [ ! -f "$DB_FILE" ]; then
        log "No database file found, skipping checkpoint"
        return 0
    fi
    
    # Check if WAL file exists and has data
    if [ ! -f "$DB_FILE-wal" ]; then
        log "No WAL file found, checkpoint not needed"
        return 0
    fi
    
    WAL_SIZE=$(ls -l "$DB_FILE-wal" 2>/dev/null | awk '{print $5}' || echo "0")
    log "WAL file size before checkpoint: $WAL_SIZE bytes"
    
    # Use sqlite3 package (built into n8n) for checkpoint
    # Note: sqlite3 is async, so we use a promise wrapper
    log "Using sqlite3 for WAL checkpoint..."
    
    CHECKPOINT_RESULT=$(node -e "
        const sqlite3 = require('/usr/local/lib/node_modules/n8n/node_modules/.pnpm/sqlite3@5.1.7/node_modules/sqlite3');
        const db = new sqlite3.Database('$DB_FILE');
        
        db.run('PRAGMA wal_checkpoint(TRUNCATE)', function(err) {
            if (err) {
                console.error('CHECKPOINT_ERROR:' + err.message);
                db.close(() => process.exit(1));
            } else {
                console.log('CHECKPOINT_SUCCESS');
                db.close(() => process.exit(0));
            }
        });
    " 2>&1)
    
    CHECKPOINT_STATUS=$?
    
    if [ $CHECKPOINT_STATUS -eq 0 ]; then
        log "WAL checkpoint completed successfully"
        log "Checkpoint result: $CHECKPOINT_RESULT"
        
        # Verify WAL file is now empty or removed
        if [ -f "$DB_FILE-wal" ]; then
            WAL_SIZE_AFTER=$(ls -l "$DB_FILE-wal" 2>/dev/null | awk '{print $5}' || echo "0")
            log "WAL file size after checkpoint: $WAL_SIZE_AFTER bytes"
        else
            log "WAL file removed after checkpoint"
        fi
        return 0
    else
        log "ERROR: WAL checkpoint failed: $CHECKPOINT_RESULT"
        return 1
    fi
}

# =============================================================================
# Graceful shutdown handler
# Called when SIGTERM/SIGINT is received from Cloud Run
# =============================================================================
graceful_shutdown() {
    log "=========================================="
    log "Received shutdown signal - starting graceful shutdown"
    log "=========================================="
    
    # Step 1: Send SIGTERM to n8n if running
    if [ -n "$N8N_PID" ] && kill -0 "$N8N_PID" 2>/dev/null; then
        log "Sending SIGTERM to n8n (PID: $N8N_PID)..."
        kill -TERM "$N8N_PID" 2>/dev/null || true
        
        # Wait for n8n to gracefully shutdown (max 30 seconds)
        log "Waiting for n8n to shutdown..."
        SHUTDOWN_WAIT=0
        while [ $SHUTDOWN_WAIT -lt 30 ] && kill -0 "$N8N_PID" 2>/dev/null; do
            sleep 1
            SHUTDOWN_WAIT=$((SHUTDOWN_WAIT + 1))
        done
        
        if kill -0 "$N8N_PID" 2>/dev/null; then
            log "WARNING: n8n did not shutdown gracefully, forcing..."
            kill -KILL "$N8N_PID" 2>/dev/null || true
        else
            log "n8n shutdown completed after $SHUTDOWN_WAIT seconds"
        fi
    fi
    
    # Step 2: Checkpoint SQLite WAL to flush all data
    log "Checkpointing SQLite WAL..."
    checkpoint_sqlite_wal || log "WARNING: Checkpoint may have failed"
    
    # Step 3: Sync filesystem to ensure GCS FUSE writes are flushed
    log "Syncing filesystem to GCS FUSE..."
    sync
    sleep 2  # Give GCS FUSE time to flush
    
    log "=========================================="
    log "Graceful shutdown completed"
    log "=========================================="
    
    exit 0
}

# Set up signal handlers for graceful shutdown
trap graceful_shutdown SIGTERM SIGINT SIGQUIT

# =============================================================================
# Wait for GCS FUSE mount to be ready
# =============================================================================
wait_for_mount() {
    log "Waiting for GCS FUSE mount at $N8N_DATA_DIR..."
    
    elapsed=0
    while [ $elapsed -lt $MAX_WAIT ]; do
        # Check if mount point is accessible and writable
        if touch "$N8N_DATA_DIR/.mount-test" 2>/dev/null; then
            rm -f "$N8N_DATA_DIR/.mount-test"
            log "GCS FUSE mount is ready!"
            return 0
        fi
        
        log "Mount not ready yet, waiting... ($elapsed/$MAX_WAIT seconds)"
        sleep $WAIT_INTERVAL
        elapsed=$((elapsed + WAIT_INTERVAL))
    done
    
    log "ERROR: GCS FUSE mount not ready after $MAX_WAIT seconds"
    return 1
}

# =============================================================================
# Check and recover SQLite database from WAL files
# =============================================================================
check_database_locks() {
    log "Checking for SQLite database state..."
    
    # Check for WAL mode files
    if [ -f "$DB_FILE-wal" ]; then
        log "Found WAL file: $DB_FILE-wal"
        WAL_SIZE=$(ls -l "$DB_FILE-wal" 2>/dev/null | awk '{print $5}' || echo "0")
        log "WAL file size: $WAL_SIZE bytes"
    fi
    
    if [ -f "$DB_FILE-shm" ]; then
        log "Found SHM file: $DB_FILE-shm"
    fi
    
    # If database exists, try to recover WAL data
    if [ -f "$DB_FILE" ]; then
        log "Database file exists: $DB_FILE"
        DB_SIZE=$(ls -l "$DB_FILE" 2>/dev/null | awk '{print $5}' || echo "0")
        log "Database file size: $DB_SIZE bytes"
        
        # IMPORTANT: Try to checkpoint WAL files to recover data from previous crash
        # Instead of deleting WAL/SHM files (which loses data), we checkpoint them
        if [ -f "$DB_FILE-wal" ] || [ -f "$DB_FILE-shm" ]; then
            log "WAL/SHM files found from previous instance"
            log "Attempting to recover data by checkpointing WAL..."
            
            if checkpoint_sqlite_wal; then
                log "Successfully recovered WAL data to main database"
            else
                log "WARNING: Could not checkpoint WAL, data may be lost"
                log "Removing stale WAL/SHM files..."
                rm -f "$DB_FILE-wal" "$DB_FILE-shm"
                sleep 2
            fi
            
            # Verify state after recovery attempt
            if [ -f "$DB_FILE-wal" ]; then
                WAL_SIZE_NOW=$(ls -l "$DB_FILE-wal" 2>/dev/null | awk '{print $5}' || echo "0")
                log "WAL file size after recovery: $WAL_SIZE_NOW bytes"
            else
                log "WAL file cleared successfully"
            fi
        fi
    else
        log "No existing database found, n8n will create a new one"
    fi
}

# =============================================================================
# Set SQLite optimizations for GCS FUSE
# =============================================================================
configure_sqlite_for_gcs() {
    log "Configuring SQLite for GCS FUSE compatibility..."
    
    # Disable memory-mapped I/O (not reliable on FUSE)
    export SQLITE_MMAP_SIZE=0
    
    # Enable WAL mode - with proper shutdown handling, WAL is safe and performant
    # WAL provides better crash recovery when properly checkpointed
    export DB_SQLITE_ENABLE_WAL=true
    
    log "SQLite configured: WAL mode enabled with checkpoint on shutdown"
}

# =============================================================================
# Main startup sequence
# =============================================================================
main() {
    log "=========================================="
    log "n8n Cloud Run Startup"
    log "=========================================="
    
    # Step 1: Wait for mount
    wait_for_mount || exit 1
    
    # Step 2: Configure SQLite for GCS FUSE
    configure_sqlite_for_gcs
    
    # Step 3: Check database and recover WAL if needed
    check_database_locks
    
    log "=========================================="
    log "Starting n8n..."
    log "=========================================="
    
    # Start n8n in background so we can handle signals
    # This allows graceful_shutdown() to checkpoint WAL before exit
    /usr/local/bin/n8n &
    N8N_PID=$!
    
    log "n8n started with PID: $N8N_PID"
    
    # Wait for n8n to exit (or until we receive a signal)
    wait "$N8N_PID"
    EXIT_CODE=$?
    
    log "n8n exited with code: $EXIT_CODE"
    
    # Final checkpoint before container exits (if not already done by signal handler)
    checkpoint_sqlite_wal || true
    sync
    
    exit $EXIT_CODE
}

main "$@"

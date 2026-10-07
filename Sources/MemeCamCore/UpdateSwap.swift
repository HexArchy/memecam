import Foundation

/// The detached helper that swaps the app bundle after MemeCam quits.
///
/// The script is constant source: every path arrives as a positional argument and is only ever used
/// quoted, so names with spaces, `'`, `$` or backticks can neither break nor inject into it.
/// All output goes to a log file, so a failed swap leaves a trace in ~/Library/Logs/MemeCam/update.log.
public enum UpdateSwap {
    /// Arguments: $1 pid to wait for, $2 installed .app, $3 verified new .app, $4 work dir to delete,
    /// $5 log file, $6 relaunch tool (`/usr/bin/open`; tests pass `/usr/bin/true`).
    public static let script = #"""
    #!/bin/sh
    PID="$1"; DEST="$2"; NEW="$3"; WORK="$4"; LOG="$5"; OPEN="$6"
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    exec >>"$LOG" 2>&1
    log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
    log "update: waiting for pid $PID to quit"
    while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
    log "update: installing $NEW -> $DEST"
    rm -rf "$DEST.old"
    if ! mv "$DEST" "$DEST.old"; then
      log "update FAILED: could not move the current app aside; it was left untouched"
    elif /usr/bin/ditto "$NEW" "$DEST"; then
      rm -rf "$DEST.old"
      /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
      log "update: installed"
    else
      log "update FAILED: copy failed, restoring the previous version"
      rm -rf "$DEST"
      mv "$DEST.old" "$DEST" || log "update FAILED: could not restore $DEST.old"
    fi
    if "$OPEN" "$DEST"; then log "update: relaunched"; else log "update FAILED: relaunch failed"; fi
    rm -rf "$WORK"
    """#

    /// Positional arguments for `script`, in order.
    public static func arguments(pid: Int32, destination: String, newApp: String, work: String,
                                 log: String, opener: String = "/usr/bin/open") -> [String] {
        [String(pid), destination, newApp, work, log, opener]
    }
}

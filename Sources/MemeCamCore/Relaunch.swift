import Foundation

/// Restarts the app after it quits (e.g. to apply a language change) without ever running two instances.
///
/// A detached shell waits for the old process to exit, then opens the bundle again. The pid and the app
/// path are positional arguments, never part of shell source, so any path is safe.
public enum Relaunch {
    /// Arguments: $1 pid to wait for, $2 .app to open, $3 opener (`/usr/bin/open`; tests pass another tool).
    /// Gives up after ~30 s (the quit was cancelled), so a later quit doesn't relaunch out of the blue.
    public static let script = #"""
    i=0
    while kill -0 "$1" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -ge 150 ]; then exit 0; fi
      sleep 0.2
    done
    exec "$3" "$2"
    """#

    /// Arguments for `/bin/sh`: a constant launcher that backgrounds `script` under nohup (so it outlives
    /// this process) and returns at once.
    public static func launcherArguments(pid: Int32, appPath: String, opener: String = "/usr/bin/open") -> [String] {
        ["-c", #"/usr/bin/nohup /bin/sh -c "$0" sh "$@" >/dev/null 2>&1 &"#, script, String(pid), appPath, opener]
    }
}

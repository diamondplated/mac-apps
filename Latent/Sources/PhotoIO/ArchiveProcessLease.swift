import Foundation

/// The shell owns the inherited stdin lease while its tool runs with /dev/null
/// stdin. A separate process group lets cancellation reap the entire tool tree
/// before the supervisor releases its lease. Arguments are positional, never code.
enum ArchiveProcessLease {
    static let supervisor = #"""
    set -m
    child=
    stop() {
        trap '' HUP INT TERM
        child=${child:-$!}
        if [ -n "$child" ]; then
            kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
        fi
        exit 143
    }
    trap stop HUP INT TERM
    "$@" </dev/null &
    child=$!
    wait "$child"
    status=$?
    # Keep the lease if a tool leaves a descendant in its process group.
    while kill -0 -- "-$child" 2>/dev/null; do /bin/sleep 0.02; done
    exit "$status"
    """#

    static func configure(_ process: Process, tool: String, arguments: [String], directory: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", supervisor, "latent-archive", tool] + arguments
        process.standardInput = try ArchiveTemporaryStorage.inheritedLease(directory)
    }
}

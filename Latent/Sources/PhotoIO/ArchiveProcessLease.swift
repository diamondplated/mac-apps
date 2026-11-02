import Foundation

/// The shell owns the inherited stdin lease while its tool runs with /dev/null
/// stdin. A separate process group lets cancellation reap the entire tool tree
/// before the supervisor releases its lease. Arguments are positional, never code.
enum ArchiveProcessLease {
    static let supervisor = #"""
    set -m
    child=
    waitGroup() {
        while kill -0 -- "-$child" 2>/dev/null; do
            # Zombies cannot write. Do not hold the lease forever waiting for an
            # unrelated parent to reap one; failed inspection stays conservative.
            if states=$(/bin/ps -g "$child" -o stat= 2>/dev/null); then
                # Only a successful, nonempty zombie-only inspection permits
                # release. An awk failure must retain the lease too.
                if inspected=$(printf '%s\n' "$states" | /usr/bin/awk 'NF {seen=1; if ($1 !~ /^Z/) live=1} END {if (seen && !live) print "zombies-only"}') &&
                   [ "$inspected" = zombies-only ]; then
                    return
                fi
            fi
            /bin/sleep 0.02
        done
    }
    stop() {
        trap '' HUP INT TERM
        child=${child:-$!}
        if [ -n "$child" ]; then
            kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
            waitGroup
        fi
        exit 143
    }
    trap stop HUP INT TERM
    "$@" </dev/null &
    child=$!
    wait "$child"
    status=$?
    # Keep the lease if a tool leaves a descendant in its process group.
    waitGroup
    exit "$status"
    """#

    static func configure(_ process: Process, tool: String, arguments: [String], directory: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", supervisor, "latent-archive", tool] + arguments
        process.standardInput = try ArchiveTemporaryStorage.inheritedLease(directory)
    }
}

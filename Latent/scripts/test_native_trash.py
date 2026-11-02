#!/usr/bin/env python3
"""Exercise the production Trash adapter on an invisible, disposable macOS volume."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile


def run(command, log, *, check=True):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=90)
    log.write_bytes(result.stdout + result.stderr)
    if check and result.returncode:
        raise RuntimeError(f"{command[0]} exited {result.returncode}; see {log}")
    return result


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"received signal {signum}")


def cleanup(image, mount, scratch):
    # Also catches an attach that mounted successfully but failed before returning.
    info = run(["hdiutil", "info", "-plist"], scratch / "cleanup-info.plist")
    for item in plistlib.loads(info.stdout).get("images", []):
        if Path(item.get("image-path", "")).resolve() != image:
            continue
        devices = [part["dev-entry"] for part in item.get("system-entities", [])
                   if part.get("dev-entry")]
        if not devices:
            raise RuntimeError("owned image is attached without a detach target")
        # The first entity is the whole device belonging to this exact image.
        run(["hdiutil", "detach", devices[0]], scratch / "detach.log")
    if os.path.ismount(mount):
        raise RuntimeError("owned mount is still mounted; preserving image")
    mount.rmdir()  # Never recursively remove a mountpoint, even after detaching.
    image.unlink(missing_ok=True)
    print("Cleanup PASS: owned image detached and removed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mutation", action="store_true",
                        help="also require a permanent-delete mutant to fail")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("requires macOS, Swift 6, hdiutil, and sandbox-exec")
    # Outside HOME: Foundation needs to traverse the mount's ancestors while HOME
    # data is denied. No caller-supplied volume or fixture path is accepted.
    scratch = Path(tempfile.mkdtemp(prefix="latent-native-trash-", dir="/private/tmp"))
    mount = scratch / "volume"
    mount.mkdir()
    image = scratch / "fixture.dmg"
    print(f"Native Trash logs: {scratch}", flush=True)
    signal.signal(signal.SIGTERM, interrupted)
    package = Path(__file__).resolve().parent.parent
    source = package / "Sources/PhotoIO/RecoverableTrash.swift"
    harness = package / "scripts/tests/native_trash/Harness.swift"
    try:
        probe = scratch / "probe"
        compiler = ["swiftc", "-swift-version", "6", "-module-cache-path",
                    str(scratch / "module-cache")]
        run([*compiler, str(source), str(harness), "-o", str(probe)],
            scratch / "compile.log")
        run(["hdiutil", "create", "-size", "64m", "-fs", "HFS+", "-volname",
             "LatentTrashFixture", "-layout", "GPTSPUD", "-nospotlight", str(image)],
            scratch / "create.log")
        run(["hdiutil", "attach", str(image), "-mountpoint", str(mount), "-nobrowse",
             "-noautoopen", "-owners", "on", "-plist"], scratch / "attach.plist")
        if not os.path.ismount(mount) or mount.stat().st_dev == scratch.stat().st_dev:
            raise RuntimeError("fixture is not mounted on its own filesystem")
        trash = mount / ".Trashes"
        trash.mkdir(exist_ok=True)
        trash.chmod(0o1777)
        user_trash = trash / str(os.getuid())
        user_trash.mkdir()
        user_trash.chmod(0o700)
        profile = scratch / "containment.sb"
        profile.write_text(
            '(version 1)\n(allow default)\n(deny network*)\n'
            '(deny user-preference-read)\n'
            f'(deny file-read-data (subpath {json.dumps(str(Path.home().resolve()))}))\n'
            '(deny file-write*)\n'
            f'(allow file-write* (subpath {json.dumps(str(mount))}))\n')
        command = ["sandbox-exec", "-f", str(profile), str(probe), str(mount)]
        result = run(command, scratch / "native.log")
        print(result.stdout.decode(), end="", flush=True)
        if args.mutation:
            original = "try FileManager.default.trashItem(at: url, resultingItemURL: &result)"
            body = source.read_text()
            if body.count(original) != 1:
                raise RuntimeError("mutation target changed; update this test explicitly")
            mutant = scratch / "Mutant.swift"
            mutant.write_text(body.replace(original, "try FileManager.default.removeItem(at: url)"))
            mutant_probe = scratch / "mutant-probe"
            run([*compiler, str(mutant), str(harness), "-o", str(mutant_probe)],
                scratch / "compile-mutant.log")
            command[-2] = str(mutant_probe)
            result = run(command, scratch / "mutant.log", check=False)
            expected = b"FAIL: native adapter returned no recoverable Trash receipt"
            if result.returncode != 1 or expected not in result.stdout:
                raise RuntimeError("permanent-delete mutant did not fail the receipt assertion")
            print("Mutation PASS: permanent-delete adapter rejected by receipt assertion", flush=True)
    finally:
        # A second termination must not interrupt detachment. SIGKILL/power loss
        # cannot be handled; the printed owned scratch path identifies recovery.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        cleanup(image, mount, scratch)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f"FAIL: {error}; logs and any undetached image are retained", file=sys.stderr)
        sys.exit(1)

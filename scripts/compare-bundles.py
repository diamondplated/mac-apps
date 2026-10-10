#!/usr/bin/env python3
"""Compare bundle structure and bytes without traversing framework symlinks."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from typing import Dict, NamedTuple, Optional


class Entry(NamedTuple):
    kind: str
    mode: Optional[int]
    content: Optional[str]


def inventory(root: Path) -> Dict[str, Entry]:
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ValueError(f"Bundle root must be a directory, not a symlink: {root}")
    entries = {}

    def visit(directory: Path) -> None:
        entries[str(directory.relative_to(root))] = Entry(
            "directory", stat.S_IMODE(directory.lstat().st_mode), None
        )
        with os.scandir(directory) as children:
            for child in children:
                path = Path(child.path)
                relative = str(path.relative_to(root))
                metadata = child.stat(follow_symlinks=False)
                if stat.S_ISLNK(metadata.st_mode):
                    # Preserve even dangling/cyclic links as their literal targets.
                    entries[relative] = Entry("symlink", None, os.readlink(path))
                elif stat.S_ISDIR(metadata.st_mode):
                    visit(path)
                elif stat.S_ISREG(metadata.st_mode):
                    digest = hashlib.sha256()
                    with path.open("rb") as data:
                        for block in iter(lambda: data.read(1024 * 1024), b""):
                            digest.update(block)
                    entries[relative] = Entry(
                        "file", stat.S_IMODE(metadata.st_mode), digest.hexdigest()
                    )
                else:
                    raise ValueError(f"Unsupported bundle entry: {path}")

    visit(root)
    return entries


def differences(expected: Path, actual: Path):
    left, right = inventory(expected), inventory(actual)
    result = []
    for path in sorted(left.keys() | right.keys()):
        if path not in right:
            result.append(f"Missing: {path}")
        elif path not in left:
            result.append(f"Unexpected: {path}")
        elif left[path] != right[path]:
            before, after = left[path], right[path]
            if before.kind != after.kind:
                result.append(f"Type changed: {path} ({before.kind} -> {after.kind})")
            else:
                if before.mode != after.mode:
                    result.append(f"Permissions changed: {path}")
                if before.content != after.content:
                    label = "Symlink target" if before.kind == "symlink" else "File bytes"
                    result.append(f"{label} changed: {path}")
    return result


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="compare-bundles-") as temporary:
        base = Path(temporary)
        expected, actual = base / "expected.app", base / "actual.app"
        version = expected / "Contents/Frameworks/Sparkle.framework/Versions/B"
        version.mkdir(parents=True)
        binary = version / "Sparkle"
        binary.write_bytes(b"binary-one")
        binary.chmod(0o755)
        framework = version.parent.parent
        (framework / "Versions/Current").symlink_to("B")
        (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
        (version / "cycle").symlink_to("..")
        (version / "dangling").symlink_to("missing")
        shutil.copytree(expected, actual, symlinks=True)
        assert not differences(expected, actual), "Identical framework symlinks must compare equal"
        copied_binary = actual / binary.relative_to(expected)
        copied_binary.write_bytes(b"binary-two")
        assert any("File bytes changed:" in d for d in differences(expected, actual))
        copied_binary.write_bytes(binary.read_bytes())
        copied_binary.chmod(0o644)
        assert any("Permissions changed:" in d for d in differences(expected, actual))
        copied_binary.chmod(0o755)
        copied_binary.unlink()
        assert any("Missing:" in d for d in differences(expected, actual))
        shutil.copy2(binary, copied_binary)
        copied_link = actual / (framework / "Versions/Current").relative_to(expected)
        copied_link.unlink()
        copied_link.symlink_to("different-target")
        assert any("Symlink target changed:" in d for d in differences(expected, actual))
        copied_link.unlink()
        copied_link.symlink_to("B")
        (actual / "unexpected").write_text("extra")
        assert any("Unexpected:" in d for d in differences(expected, actual))
        (actual / "unexpected").unlink()
        assert not differences(expected, actual)
    print("Bundle comparison self-tests passed (bytes, missing/extra files, modes, symlinks, cycles).")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected", nargs="?", type=Path)
    parser.add_argument("actual", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        if args.expected or args.actual:
            parser.error("--self-test takes no bundle paths")
        self_test()
        return 0
    if args.expected is None or args.actual is None:
        parser.error("provide expected and actual bundle paths")
    try:
        mismatches = differences(args.expected.absolute(), args.actual.absolute())
    except (OSError, ValueError) as error:
        print(f"Bundle comparison failed: {error}", file=sys.stderr)
        return 2
    if mismatches:
        for mismatch in mismatches[:40]:
            print(mismatch, file=sys.stderr)
        if len(mismatches) > 40:
            print(f"... and {len(mismatches) - 40} more differences", file=sys.stderr)
        return 1
    print(f"Bundle contents match: {args.actual}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

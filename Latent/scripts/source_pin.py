"""Fetch architecture source at an audited revision and refuse changed caches."""
from pathlib import Path
import subprocess


def ensure_pinned_repo(url: str, directory: Path, revision: str) -> None:
    def git(*args: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(directory), *args], text=True
        ).strip()

    if directory.is_symlink():
        raise RuntimeError(f"Refusing symlinked architecture checkout: {directory}")
    if not directory.exists():
        directory.mkdir(parents=True)
        git("init")
        git("fetch", "--depth", "1", url, revision)
        git("checkout", "--detach", "FETCH_HEAD")
    # Never reset an existing checkout: it may contain the user's work.
    if git("rev-parse", "HEAD") != revision:
        raise RuntimeError(f"Architecture checkout is not pinned to {revision}: {directory}")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError(f"Architecture checkout has tracked changes: {directory}")
    # Include ignored files: an ignored Python module can shadow a pinned module.
    # CPython's __pycache__ bytecode cannot be imported without its source file.
    extras = git("ls-files", "--others").splitlines()
    if any(not ("__pycache__" in Path(p).parts and p.endswith(".pyc")) for p in extras):
        raise RuntimeError(f"Architecture checkout has untracked files: {directory}")

"""Offline supply-chain regressions; no ML packages or model weights required."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import convert_openclip
from fetch import ChecksumMismatch
from source_pin import ensure_pinned_repo


class ArchitecturePinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "source"
        self.source.mkdir()
        self.git("init")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.source / "model.py").write_text("VALUE = 1\n")
        (self.source / ".gitignore").write_text("ignored.py\n__pycache__/\n")
        self.git("add", ".")
        self.git("commit", "-m", "Fixture")
        self.revision = self.git("rev-parse", "HEAD")
        self.destination = Path(self.temp.name) / "checkout"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()

    def ensure(self):
        ensure_pinned_repo(self.source.as_uri(), self.destination, self.revision)

    def test_fetch_and_reuse_exact_revision(self):
        self.ensure()
        self.ensure()
        self.assertEqual((self.destination / "model.py").read_text(), "VALUE = 1\n")

    def test_wrong_revision_is_refused_without_reset(self):
        self.ensure()
        self.revision = "0" * 40
        with self.assertRaisesRegex(RuntimeError, "not pinned"):
            self.ensure()

    def test_modified_code_is_refused(self):
        self.ensure()
        (self.destination / "model.py").write_text("raise Exception('tampered')\n")
        with self.assertRaisesRegex(RuntimeError, "tracked changes"):
            self.ensure()

    def test_ignored_shadow_module_is_refused(self):
        self.ensure()
        (self.destination / "ignored.py").write_text("raise Exception('shadow')\n")
        with self.assertRaisesRegex(RuntimeError, "untracked files"):
            self.ensure()

    def test_ignored_bytecode_is_refused_without_deleting_user_files(self):
        self.ensure()
        cache = self.destination / "__pycache__"
        cache.mkdir()
        bytecode = cache / "model.cpython-312.pyc"
        bytecode.write_bytes(b"cache")
        with self.assertRaisesRegex(RuntimeError, "untracked files.*bytecode"):
            self.ensure()
        self.assertEqual(bytecode.read_bytes(), b"cache")


class CheckpointPinTests(unittest.TestCase):
    def test_only_verified_local_safetensors_reach_openclip(self):
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "source"
            source.write_bytes(b"fixture safetensors")
            target = Path(td) / "open_clip_model.safetensors"
            calls = []
            def create(name, pretrained):
                calls.append((name, pretrained))
                self.assertEqual(Path(pretrained).read_bytes(), source.read_bytes())
                return "model", None, None
            with patch.dict(sys.modules, open_clip=types.SimpleNamespace(create_model_and_transforms=create)), \
                 patch.object(convert_openclip, "WEIGHTS_URL", source.as_uri()), \
                 patch.object(convert_openclip, "WEIGHTS_FILE", target), \
                 patch.object(convert_openclip, "WEIGHTS_SHA256", hashlib.sha256(source.read_bytes()).hexdigest()):
                self.assertEqual(convert_openclip.load_model(), "model")
                self.assertEqual(calls, [("ViT-B-32", str(target))])
                target.write_bytes(b"tampered cache")
                convert_openclip.load_model()
                with patch.object(convert_openclip, "WEIGHTS_SHA256", "0" * 64):
                    with self.assertRaises(ChecksumMismatch):
                        convert_openclip.load_model()
                self.assertEqual(len(calls), 2, "a bad checksum must never reach deserialization")
                self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Verify a unique GitHub draft and its exact assets; optionally publish by ID."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


def github(endpoint, method="GET", fields=()):
    command = ["gh", "api", endpoint]
    if method != "GET":
        command += ["--method", method]
    command += list(fields)
    return json.loads(subprocess.check_output(command, text=True))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as content:
        for block in iter(lambda: content.read(1024 * 1024), b""):
            digest.update(block)
    return "sha256:" + digest.hexdigest()


def verify(repository, version, directory):
    tag = "v" + version
    matches = []
    page = 1
    while True:
        # GitHub's tag lookup can return 404 for unpublished drafts. The
        # authenticated list includes drafts; resolve once, then use the ID.
        releases = github(f"repos/{repository}/releases?per_page=100&page={page}")
        matches.extend(release for release in releases if release.get("tag_name") == tag)
        if len(releases) < 100:
            break
        page += 1
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one release for {tag}; found {len(matches)}. Draft retained.")
    if matches[0].get("draft") is not True:
        raise ValueError("Expected an unpublished draft release.")
    release_id = matches[0].get("id")
    if type(release_id) is not int or release_id <= 0:
        raise ValueError("GitHub returned an invalid release ID.")
    release = github(f"repos/{repository}/releases/{release_id}")
    if release.get("id") != release_id or release.get("tag_name") != tag or release.get("draft") is not True:
        raise ValueError("Draft ID, tag, or publication state changed during verification.")
    expected = [f"Mac-Tools-{version}.zip", "appcast.xml", f"Mac-Tools-{version}.md",
                f"Mac-Tools-{version}.zip.ed25519", "SHA256SUMS", "release.json"]
    uploaded = release.get("assets", [])
    assets = {asset["name"]: asset for asset in uploaded}
    if len(assets) != len(uploaded) or set(assets) != set(expected):
        raise ValueError("Release asset inventory is missing, duplicated, or unexpected; draft retained.")
    for name in expected:
        asset = assets[name]
        local = directory / name
        if not local.is_file() or local.is_symlink():
            raise ValueError(f"Local release asset is not a regular file: {name}")
        if asset.get("state") != "uploaded" or asset.get("size") != local.stat().st_size:
            raise ValueError(f"Release asset upload is incomplete or the size differs; draft retained: {name}")
        # GitHub supplies SHA256 digests for uploaded release assets. A missing
        # digest is incomplete evidence, never a reason to skip byte verification.
        if asset.get("digest") != sha256(local):
            raise ValueError(f"Release asset SHA256 digest is missing or differs; draft retained: {name}")
    return release_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", nargs="?")
    parser.add_argument("version", nargs="?")
    parser.add_argument("directory", nargs="?", type=Path)
    parser.add_argument("--publish", action="store_true", help="Publish the exact validated ID after all checks.")
    parser.add_argument("--self-test", action="store_true", help="Run offline fixtures using a fake gh executable.")
    args = parser.parse_args()
    if args.self_test:
        if args.repository or args.version or args.directory or args.publish:
            parser.error("--self-test takes no other arguments")
        return self_test()
    if not args.repository or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("repository must be owner/name")
    if not args.version or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version) or args.directory is None:
        parser.error("provide version X.Y.Z and the release directory")
    try:
        release_id = verify(args.repository, args.version, args.directory)
        if args.publish:
            release = github(f"repos/{args.repository}/releases/{release_id}", "PATCH",
                             ("-F", "draft=false", "-f", "make_latest=true"))
            if release.get("id") != release_id or release.get("tag_name") != "v" + args.version or release.get("draft") is not False:
                raise ValueError("GitHub did not confirm publication of the validated release ID.")
            print(release["html_url"])
        else:
            print(release_id)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Release draft verification failed: {error}", file=sys.stderr)
        return 1
    return 0


def self_test():
    class DraftFixtures(unittest.TestCase):
        def setUp(self):
            self.temporary = tempfile.TemporaryDirectory(prefix="release-draft-fixtures-")
            self.root = Path(self.temporary.name)
            self.directory = self.root / "release"
            self.directory.mkdir()
            self.endpoint = "repos/example/downloads/releases"
            self.release_id = 409200238
            names = ["Mac-Tools-1.1.0.zip", "appcast.xml", "Mac-Tools-1.1.0.md",
                     "Mac-Tools-1.1.0.zip.ed25519", "SHA256SUMS", "release.json"]
            assets = []
            for name in names:
                path = self.directory / name
                path.write_bytes(("fixture-" + name).encode())
                assets.append(dict(name=name, state="uploaded", size=path.stat().st_size, digest=sha256(path)))
            self.draft = dict(id=self.release_id, tag_name="v1.1.0", draft=True, assets=assets)
            self.responses = {
                f"GET {self.endpoint}?per_page=100&page=1": [self.draft],
                f"GET {self.endpoint}/{self.release_id}": self.draft,
                f"PATCH {self.endpoint}/{self.release_id}": dict(id=self.release_id, tag_name="v1.1.0", draft=False,
                    html_url="https://github.com/example/downloads/releases/tag/v1.1.0"),
            }
            self.fixture = self.root / "responses.json"
            self.calls = self.root / "calls.jsonl"
            fake = self.root / "gh"
            fake.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
args=sys.argv[1:]
assert args[0] == 'api'
endpoint=args[1]
method=args[args.index('--method')+1] if '--method' in args else 'GET'
with open(os.environ['DRAFT_FIXTURE_CALLS'],'a') as log:
    log.write(json.dumps(args)+'\\n')
responses=json.load(open(os.environ['DRAFT_FIXTURE_RESPONSES']))
key=method+' '+endpoint
if key not in responses:
    print('Unexpected fake API call: '+key,file=sys.stderr)
    sys.exit(90)
print(json.dumps(responses[key]))
''')
            fake.chmod(0o755)

        def tearDown(self):
            self.temporary.cleanup()

        def run_fixture(self, publish=True):
            self.fixture.write_text(json.dumps(self.responses))
            env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                       DRAFT_FIXTURE_CALLS=str(self.calls), DRAFT_FIXTURE_RESPONSES=str(self.fixture))
            command = [sys.executable, str(Path(__file__).resolve()), "example/downloads", "1.1.0", str(self.directory)]
            if publish:
                command.append("--publish")
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
            return result, calls

        def assert_rejected(self):
            result, calls = self.run_fixture()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any("PATCH" in call for call in calls), result.stderr)

        def test_valid_draft_publishes_exact_id(self):
            result, calls = self.run_fixture()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls[-1], ["api", f"{self.endpoint}/{self.release_id}", "--method", "PATCH",
                                         "-F", "draft=false", "-f", "make_latest=true"])
            self.assertFalse(any("/tags/" in call[1] for call in calls))

        def test_read_only_validation_returns_id(self):
            result, calls = self.run_fixture(publish=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(self.release_id))
            self.assertFalse(any("PATCH" in call for call in calls))

        def test_missing_tag(self):
            self.responses[f"GET {self.endpoint}?per_page=100&page=1"] = []
            self.assert_rejected()

        def test_duplicate_tag(self):
            self.responses[f"GET {self.endpoint}?per_page=100&page=1"] = [self.draft, dict(self.draft, id=42)]
            self.assert_rejected()

        def test_not_draft(self):
            self.draft["draft"] = False
            self.assert_rejected()

        def test_detail_state_changed(self):
            self.responses[f"GET {self.endpoint}/{self.release_id}"] = dict(self.draft, draft=False)
            self.assert_rejected()

        def test_detail_id_changed(self):
            self.responses[f"GET {self.endpoint}/{self.release_id}"] = dict(self.draft, id=42)
            self.assert_rejected()

        def test_missing_asset(self):
            self.draft["assets"].pop()
            self.assert_rejected()

        def test_incomplete_asset(self):
            self.draft["assets"][0]["state"] = "new"
            self.assert_rejected()

        def test_wrong_asset_size(self):
            self.draft["assets"][0]["size"] += 1
            self.assert_rejected()

        def test_wrong_asset_digest(self):
            self.draft["assets"][0]["digest"] = "sha256:" + "0" * 64
            self.assert_rejected()

        def test_missing_asset_digest(self):
            self.draft["assets"][0]["digest"] = None
            self.assert_rejected()

        def test_paginated_lookup(self):
            self.responses[f"GET {self.endpoint}?per_page=100&page=1"] = [dict(id=i, tag_name=f"v0.0.{i}", draft=False) for i in range(100)]
            self.responses[f"GET {self.endpoint}?per_page=100&page=2"] = [self.draft]
            result, calls = self.run_fixture()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(any("page=2" in call[1] for call in calls))

    result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(DraftFixtures))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())

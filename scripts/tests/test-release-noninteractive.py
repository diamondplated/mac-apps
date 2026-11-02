"""Exercise release orchestration with command stubs; never read real credentials."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ReleaseDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'docs/releases').mkdir(parents=True)
        (self.root / 'docs/releases/1.3.1.md').write_text('Synthetic notes')
        shutil.copy(ROOT / 'scripts/release.sh', self.root / 'scripts/release.sh')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.trace = self.root / 'trace'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        TRACE=str(self.trace), SCREENWREN_SIGNING_IDENTITY='Synthetic persistent identity',
                        SCREENWREN_LIVE_QA='0', SPARKLE_TOOLS_DIR=str(self.bin),
                        MACTOOLS_RELEASE_REPOSITORY='example/releases',
                        SPARKLE_KEYCHAIN_ACCOUNT='synthetic-account')
        self.stub('plutil', '''#!/usr/bin/env python3
import os,sys
with open(os.environ['TRACE'],'a') as f:f.write('plutil\\n')
values={'CFBundleShortVersionString':'1.3.1','CFBundleVersion':'9','SUFeedURL':'https://github.com/example/releases/releases/latest/download/appcast.xml','MacToolsReleasesURL':'https://github.com/example/releases/releases','SUPublicEDKey':'PUBLIC_FIXTURE','SURequireSignedFeed':'true','SUVerifyUpdateBeforeExtraction':'true'}
print(values[sys.argv[2]])
''')
        self.stub('gh', '#!/bin/bash\necho gh >> "$TRACE"\necho false\n')
        self.stub('swiftc', '''#!/usr/bin/env python3
import os,pathlib,sys
with open(os.environ['TRACE'],'a') as f:f.write('compile-helper\\n')
p=pathlib.Path(sys.argv[sys.argv.index('-o')+1])
p.write_text('#!/bin/bash\\necho helper >> "$TRACE"\\nexit "${HELPER_STATUS:-0}"\\n')
p.chmod(0o755)
''')
        for name in ['generate_keys', 'generate_appcast', 'sign_update', 'security', 'swift', 'xcrun']:
            self.stub(name, '#!/bin/bash\necho forbidden-official-or-live >> "$TRACE"\nexit 99\n')

    def stub(self, name, content):
        p = self.bin / name
        p.write_text(content)
        p.chmod(0o755)

    def run_release(self, *args):
        return subprocess.run(['bash', str(self.root / 'scripts/release.sh'), *args],
                              env=self.env, capture_output=True, text=True)

    def test_invalid_combinations_stop_before_credential_commands(self):
        for args in [('--noninteractive',), ('--local', '--noninteractive'),
                     ('--notarized', '--preflight', '--noninteractive'),
                     ('--local', '--preflight', '--noninteractive', '--publish')]:
            with self.subTest(args=args):
                result = self.run_release(*args)
                self.assertEqual(result.returncode, 64)
                self.assertFalse(self.trace.exists())

    def test_diagnostic_success_does_not_claim_official_tool_access(self):
        result = self.run_release('--local', '--preflight', '--noninteractive')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('official Sparkle tool access remains unverified', result.stdout)
        self.assertNotIn('Release preflight passed', result.stdout)
        self.assertNotIn('PUBLIC_FIXTURE', result.stdout + result.stderr)
        self.assertNotIn('forbidden', self.trace.read_text())
        self.assertEqual(self.trace.read_text().count('helper\n'), 2)  # compile-helper + helper

    def test_ordinary_preflight_still_uses_official_tool(self):
        self.stub('generate_keys', '#!/bin/bash\necho official-generate-keys >> "$TRACE"\necho PUBLIC_FIXTURE\n')
        result = self.run_release('--local', '--preflight')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Release preflight passed', result.stdout)
        trace = self.trace.read_text()
        self.assertIn('official-generate-keys', trace)
        self.assertNotIn('compile-helper', trace)
        self.assertNotIn('PUBLIC_FIXTURE', result.stdout + result.stderr)

    def test_ordinary_preflight_rejects_public_key_mismatch(self):
        self.stub('generate_keys', '#!/bin/bash\necho official-generate-keys >> "$TRACE"\necho WRONG_PUBLIC_FIXTURE\n')
        result = self.run_release('--local', '--preflight')
        self.assertEqual(result.returncode, 1)
        self.assertIn('does not match', result.stderr)
        self.assertNotIn('PUBLIC_FIXTURE', result.stdout + result.stderr)
        self.assertNotIn('compile-helper', self.trace.read_text())

    def test_denial_never_falls_back_or_prints_identity(self):
        self.env['HELPER_STATUS'] = '1'
        result = self.run_release('--local', '--preflight', '--noninteractive')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('passed', result.stdout)
        self.assertNotIn('PUBLIC_FIXTURE', result.stdout + result.stderr)
        self.assertNotIn('forbidden', self.trace.read_text())

if __name__ == '__main__':
    unittest.main()

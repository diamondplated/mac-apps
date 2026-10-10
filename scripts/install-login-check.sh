#!/bin/sh
# Install only: intentionally never bootstrap, kickstart, log out, or reboot.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec /usr/bin/python3 - "$SCRIPT_DIR/verify-login.sh" <<'PY'
import datetime, json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile, uuid

if os.getuid() == 0 or os.getuid() != os.geteuid():
    raise SystemExit('Run as the logged-in user, without sudo.')
source = pathlib.Path(sys.argv[1])
if not source.is_file() or source.is_symlink() or source.stat().st_uid != os.getuid():
    raise SystemExit('The verifier must be a regular file owned by the current user.')
result = subprocess.run([str(source), '--current'], capture_output=True, text=True, timeout=75)
try: preflight = json.loads(result.stdout)
except Exception: raise SystemExit('Cannot capture the login-session baseline: ' + result.stderr.strip())
if not preflight.get('sessionIdentity'):
    raise SystemExit('Cannot arm verification without a current graphical login-session baseline.')
root = pathlib.Path.home() / 'Library/Application Support/Mac Tools/Verification'
launch_agents = pathlib.Path.home() / 'Library/LaunchAgents'
for directory in [root, launch_agents]:
    for ancestor in [directory, *directory.parents]:
        if ancestor.is_symlink(): raise SystemExit('Refusing a symbolic-link installation directory.')
    directory.mkdir(parents=True, exist_ok=True)
    if directory.stat().st_uid != os.getuid(): raise SystemExit('Installation directory is not owned by the current user.')
root.chmod(0o700)
label = 'com.andrew.mactools.verify-login'
agent = launch_agents / (label + '.plist')
verifier = root / 'verify-login.sh'
for path in [agent, verifier, root / 'baseline.json', root / 'completed.json']:
    if path.is_symlink(): raise SystemExit('Refusing a symbolic-link installation file.')

def atomic(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix='.login-check-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle: handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

token = str(uuid.uuid4())
baseline = {'schemaVersion': 1, 'token': token, 'uid': os.getuid(),
            'recordedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'sessionIdentity': preflight['sessionIdentity']}
job = {'Label': label, 'ProgramArguments': [str(verifier), '--at-login', '--token', token],
       'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua', 'ProcessType': 'Background',
       'StandardOutPath': str(root / 'launchagent.log'), 'StandardErrorPath': str(root / 'launchagent-error.log')}
atomic(verifier, source.read_bytes(), 0o700)
atomic(root / 'baseline.json', (json.dumps(baseline, indent=2) + '\n').encode(), 0o600)
atomic(agent, plistlib.dumps(job), 0o600)
print('Armed one native check for the next login; the job was not loaded into this session.')
print('Report: ' + str(root / 'login-check.json'))
print('No apps or startup settings were changed. No logout or reboot was requested.')
PY

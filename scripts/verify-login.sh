#!/bin/sh
# Read-only app verification; --at-login also writes its one-time evidence report.
exec /usr/bin/python3 - "$@" <<'PY'
import argparse, ctypes, datetime, json, os, pathlib, plistlib, re, subprocess, sys, tempfile, time

LABEL = 'com.andrew.mactools.verify-login'
APPS = [('dockPeek', 'DockPeek', 'com.andrew.dockpeek'),
        ('screenWren', 'ScreenWren', 'io.github.diamondplated.ScreenWren')]
ROOT = pathlib.Path.home() / 'Library/Application Support/Mac Tools/Verification'
AGENT = pathlib.Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')

def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def command(args, timeout=10):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('%s failed: %s' % (pathlib.Path(args[0]).name, result.stderr.strip()[:300]))
    return result.stdout.strip()

def session_identity():
    gui = command(['/bin/launchctl', 'print', 'gui/%d' % os.getuid()])
    match = re.search(r'^\s*asid = (\d+)\s*$', gui, re.M)
    if not match:
        raise RuntimeError('No current graphical login audit-session ID is available.')
    return {'auditSessionID': match.group(1),
            'bootSessionUUID': command(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']),
            'uid': os.getuid()}

def validate_login_context(identity, baseline, parent_pid):
    if parent_pid != 1:
        raise RuntimeError('The next-login check must be started by the native LaunchAgent.')
    if identity == baseline.get('sessionIdentity'):
        raise RuntimeError('The login session has not changed; this is not next-login evidence.')

def signing_mode(app_key, identifier, details, return_code=0):
    if return_code or ('Identifier=' + identifier + '\n') not in details:
        raise RuntimeError('Installed signature identifier does not match the expected app.')
    mode = 'adhoc' if 'Signature=adhoc' in details else 'persistent'
    if app_key == 'screenWren' and mode != 'persistent':
        raise RuntimeError('ScreenWren requires a persistent signing identity to preserve capture permissions.')
    return mode

def installed_state(app):
    key, name, identifier = app
    candidates = [pathlib.Path('/Applications') / (name + '.app'),
                  pathlib.Path.home() / 'Applications' / (name + '.app')]
    bundle = next((p for p in candidates if p.is_dir()), None)
    if bundle is None:
        raise RuntimeError('%s is not installed in Applications.' % name)
    roots = [pathlib.Path('/Applications').resolve(), (pathlib.Path.home() / 'Applications').resolve()]
    bundle = bundle.resolve()
    if bundle.parent not in roots:
        raise RuntimeError('Installed app resolves outside the expected Applications directories.')
    with (bundle / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    if info.get('CFBundleIdentifier') != identifier or info.get('CFBundleExecutable') != name:
        raise RuntimeError('Installed bundle identity or executable does not match %s.' % name)
    if info.get('MacToolsSettingsProtocolVersion') != 1:
        raise RuntimeError('%s needs an update before startup status can be inspected.' % name)
    executable = (bundle / 'Contents/MacOS' / name).resolve()
    if executable.parent != bundle / 'Contents/MacOS':
        raise RuntimeError('Installed executable resolves outside its bundle.')
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)])
    signature = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(bundle)],
                               capture_output=True, text=True, timeout=10)
    details = signature.stderr
    mode = signing_mode(key, identifier, details, signature.returncode)
    state = json.loads(command([str(executable), '--mac-tools-settings', 'read']))
    if state.get('schemaVersion') != 1 or state.get('app') != key or type(state.get('launchAtLogin')) is not bool:
        raise RuntimeError('Unexpected settings response from %s.' % name)
    # Keep only startup state. Capture settings, shortcuts and other preferences are never recorded.
    return {'app': key, 'bundlePath': str(bundle), 'bundleIdentifier': identifier,
            'executablePath': str(executable), 'signatureVerified': True, 'signingMode': mode,
            'launchAtLogin': state['launchAtLogin'], 'loginStatus': str(state.get('loginStatus', 'Unknown'))}

def running_paths(name):
    result = subprocess.run(['/usr/bin/pgrep', '-u', str(os.getuid()), '-x', name],
                            capture_output=True, text=True, timeout=5)
    if result.returncode not in (0, 1):
        raise RuntimeError('Cannot inspect running processes.')
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    paths = []
    for pid in result.stdout.split():
        buffer = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(int(pid), buffer, len(buffer)) > 0:
            paths.append((int(pid), str(pathlib.Path(os.fsdecode(buffer.value)).resolve())))
    return paths

def observe(states, processes, now, sleep, wait_seconds):
    """Injectable observer; never launches an app or changes preferences."""
    deadline = now() + wait_seconds
    while True:
        complete = True
        for state in states:
            if 'error' in state:
                complete = False
                continue
            name = next(app[1] for app in APPS if app[0] == state['app'])
            matches = processes(name)
            state['matchingProcessIDs'] = [pid for pid, path in matches if path == state['executablePath']]
            state['otherCopyRunning'] = any(path != state['executablePath'] for _, path in matches)
            state['runningFromExpectedBundle'] = bool(state['matchingProcessIDs'])
            state['result'] = ('not-enabled' if not state['launchAtLogin'] else
                               'running' if state['runningFromExpectedBundle'] else 'not-running')
            if state['launchAtLogin'] and not state['runningFromExpectedBundle']:
                complete = False
        if complete or now() >= deadline:
            return states
        sleep(min(2, max(0, deadline - now())))

def atomic_json(path, value):
    if path.parent.is_symlink() or path.is_symlink():
        raise RuntimeError('Refusing a symbolic-link report path.')
    fd, temporary = tempfile.mkstemp(prefix='.login-check-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def self_test():
    # Fixtures cannot create a login report or claim observed login evidence.
    def state():
        return {'app': 'dockPeek', 'launchAtLogin': True, 'executablePath': '/Applications/DockPeek.app/Contents/MacOS/DockPeek'}
    clock = [0]
    def sleep(seconds): clock[0] += seconds
    value = state()
    observe([value], lambda _: [(42, value['executablePath'])] if clock[0] >= 4 else [],
            lambda: clock[0], sleep, 10)
    assert value['runningFromExpectedBundle'] and clock[0] == 4
    clock[0] = 0
    value = state()
    observe([value], lambda _: [(42, '/tmp/DockPeek.app/Contents/MacOS/DockPeek')], lambda: clock[0], sleep, 6)
    assert value['otherCopyRunning'] and not value['runningFromExpectedBundle'] and clock[0] == 6
    clock[0] = 0
    value = state()
    observe([value], lambda _: [], lambda: clock[0], sleep, 6)
    assert value['result'] == 'not-running' and clock[0] == 6
    value = state(); value['launchAtLogin'] = False
    observe([value], lambda _: [], lambda: 0, lambda _: None, 90)
    assert value['result'] == 'not-enabled'
    baseline = {'sessionIdentity': {'auditSessionID': '1', 'bootSessionUUID': 'fixture', 'uid': 501}}
    for identity, parent in [(baseline['sessionIdentity'], 1), ({'auditSessionID': '2'}, 42)]:
        try: validate_login_context(identity, baseline, parent)
        except RuntimeError: pass
        else: raise AssertionError('Invalid login evidence context accepted')
    validate_login_context({'auditSessionID': '2', 'bootSessionUUID': 'fixture', 'uid': 501}, baseline, 1)
    dock_signature = 'Identifier=com.andrew.dockpeek\nSignature=adhoc\n'
    screen_signature = 'Identifier=io.github.diamondplated.ScreenWren\nAuthority=Fixture certificate\n'
    assert signing_mode('dockPeek', 'com.andrew.dockpeek', dock_signature) == 'adhoc'
    assert signing_mode('screenWren', 'io.github.diamondplated.ScreenWren', screen_signature) == 'persistent'
    for key, identifier, details in [
        ('screenWren', 'io.github.diamondplated.ScreenWren', screen_signature + 'Signature=adhoc\n'),
        ('dockPeek', 'com.andrew.dockpeek', 'Identifier=wrong\nSignature=adhoc\n')]:
        try: signing_mode(key, identifier, details)
        except RuntimeError: pass
        else: raise AssertionError('Invalid signing policy accepted')
    print(json.dumps({'result': 'passed', 'tests': 11, 'evidence': 'simulated', 'loginVerified': False}))

def main():
    parser = argparse.ArgumentParser(description='Inspect current startup state or perform one native next-login check.')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--current', action='store_true')
    mode.add_argument('--at-login', action='store_true')
    mode.add_argument('--self-test', action='store_true')
    parser.add_argument('--token')
    args = parser.parse_args()
    if args.self_test:
        self_test(); return 0
    if os.getuid() == 0 or os.getuid() != os.geteuid():
        raise RuntimeError('Run as the logged-in user, without sudo.')
    report = {'schemaVersion': 1, 'phase': 'next-login' if args.at_login else 'preflight',
              'startedAt': timestamp(), 'evidence': 'observed', 'loginVerified': False,
              'result': 'incomplete', 'apps': []}
    baseline = None
    if args.at_login:
        baseline_file = ROOT / 'baseline.json'
        if baseline_file.is_symlink() or baseline_file.stat().st_uid != os.getuid():
            raise RuntimeError('Invalid verification baseline ownership.')
        baseline = json.loads(baseline_file.read_text())
        if not args.token or args.token != baseline.get('token') or baseline.get('uid') != os.getuid():
            raise RuntimeError('This invocation does not match the installed verification job.')
        marker = ROOT / 'completed.json'
        if marker.exists() and json.loads(marker.read_text()).get('token') == args.token:
            return 0
        if os.getppid() != 1:
            raise RuntimeError('The next-login check must be started by the native LaunchAgent.')
    try:
        report['sessionIdentity'] = session_identity()
        if baseline:
            report['baselineRecordedAt'] = baseline['recordedAt']
            validate_login_context(report['sessionIdentity'], baseline, os.getppid())
        for app in APPS:
            try: report['apps'].append(installed_state(app))
            except Exception as error: report['apps'].append({'app': app[0], 'result': 'error', 'error': str(error)})
        observe(report['apps'], running_paths, time.monotonic, time.sleep, 90 if baseline else 0)
        passed = all(app.get('launchAtLogin') and app.get('runningFromExpectedBundle') for app in report['apps'])
        report['result'] = 'passed' if passed else 'failed'
        report['loginVerified'] = bool(baseline and passed)
    except Exception as error:
        report['result'] = 'failed'
        report['error'] = str(error)
    report['finishedAt'] = timestamp()
    report['interpretation'] = ('Apps were observed running from their expected installed bundles in a new login session with startup enabled. '
                                'This does not prove they were never launched manually.' if report['loginVerified'] else
                                'Current startup configuration and process checks are not proof of a successful new login.' if not baseline else
                                'The one-time next-login check did not verify both apps; inspect the recorded errors and state.')
    if baseline:
        atomic_json(ROOT / 'login-check.json', report)
        atomic_json(ROOT / 'completed.json', {'token': args.token, 'finishedAt': report['finishedAt']})
        if AGENT.exists() and not AGENT.is_symlink():
            with AGENT.open('rb') as handle: job = plistlib.load(handle)
            if job.get('Label') == LABEL and args.token in job.get('ProgramArguments', []): AGENT.unlink()
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report['result'] == 'passed' else 1

try:
    sys.exit(main())
except Exception as error:
    print('Login verification: %s' % error, file=sys.stderr)
    sys.exit(1)
PY

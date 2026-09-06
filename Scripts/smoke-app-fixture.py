#!/usr/bin/env python3
"""Build and drive the actual fixture app; retain receipts after process cleanup."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / '.build/proof' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
PROOF.mkdir(parents=True)
PB = os.environ.get('PEEKABOO_BIN') or shutil.which('peekaboo')
if not PB:
    raise SystemExit('Peekaboo 4 is required. See docs/development.md.')


def run(args, name=None):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=120)
    if name:
        (PROOF / name).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr or result.stdout}')
    return result.stdout


def peek(args, name):
    data = json.loads(run([PB, *args, '--json'], name))
    if not data.get('success'):
        raise RuntimeError(f'Peekaboo failed. See {PROOF / name}')
    return data['data']


def wait_for(operation, predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while True:
        value = operation()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError('UI readiness timed out. Inspect proof receipts.')
        time.sleep(0.25)


def inspect(name):
    return json.loads(run([str(ROOT / '.build/inspect-ui'), str(process.pid)], name))


process = None
try:
    version = peek(['--version'], 'peekaboo-version.json')
    if not version['current'].startswith('Peekaboo 4.'):
        raise RuntimeError('Peekaboo 4 is required.')
    peek(['permissions', 'status', '--all-sources'], 'permissions.json')
    existing = peek(['app', 'list', '--include-hidden', '--include-background'], 'apps-before.json')
    if 'be.bram.vikingbar' in json.dumps(existing):
        raise RuntimeError('A VikingBar instance is already running. Quit it before fixture proof.')
    run(['./Scripts/package-app.sh'], 'build.log')
    bundle = ROOT / '.build/app/VikingBar.app'
    executable = bundle / 'Contents/MacOS/VikingBarApp'
    run(['swiftc', 'Scripts/inspect-ui.swift', '-o', '.build/inspect-ui'], 'probe-build.log')
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        assert plistlib.load(stream)['LSUIElement'] is True
    app_log = (PROOF / 'app.log').open('w')
    process = subprocess.Popen([str(executable), '--fixture', 'finite'], cwd=ROOT,
                               stdout=app_log, stderr=subprocess.STDOUT)
    receipt = {'pid': process.pid, 'parentPID': os.getpid(), 'bundle': str(bundle),
               'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
               'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'arguments': ['--fixture', 'finite']}
    (PROOF / 'process.json').write_text(json.dumps(receipt, indent=2))
    run(['ps', '-p', str(process.pid), '-o', 'pid=,ppid=,lstart=,command='], 'process.txt')
    screens = peek(['screen', 'list'], 'screens.json')['screens']

    def visible_status(data):
        for element in data['elements']:
            if element.get('AXIdentifier') != 'vikingbar.status':
                continue
            (x, y), (width, height) = element['frame']
            if width > 0 and height > 0 and any(
                x >= screen['bounds']['x'] and y >= screen['bounds']['y']
                and x + width <= screen['bounds']['x'] + screen['bounds']['width']
                and y + height <= screen['bounds']['y'] + screen['bounds']['height']
                for screen in screens
            ):
                return True
        return False

    observed = wait_for(lambda: inspect('status.json'), visible_status)
    assert observed['activationPolicy'] == 1, 'App must use accessory policy without a Dock icon.'
    peek(['see', '--mode', 'screen', '--no-elements', '--path', str(PROOF / 'before.png')], 'before.json')
    run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'press', 'vikingbar.status'], 'click.json')
    card = wait_for(lambda: inspect('card.json'),
                    lambda data: any(e.get('AXIdentifier') == 'vikingbar.remaining' for e in data['elements']))
    text = json.dumps(card)
    for label in ['FIXTURE', '36.00 GB', '14.00 GB used', '28% used', 'Expires', 'Last updated']:
        assert label in text, f'Missing card text: {label}'
    window = next(w for w in card['windows'] if w['kCGWindowBounds']['Height'] > 100)
    peek(['see', '--window-id', str(window['kCGWindowNumber']), '--no-elements', '--no-remote',
          '--path', str(PROOF / 'card.png')], 'card-image.json')
    for state, expected in [('Unlimited', 'Unlimited allowance'), ('Exhausted', 'Data exhausted'),
                            ('Stale', 'Showing an older balance'), ('Error', 'Could not load the example balance')]:
        run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'press', 'vikingbar.fixturePicker'],
            f'{state.lower()}-picker.json')
        inspect(f'{state.lower()}-menu.json')
        run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'press', state], f'{state.lower()}-select.json')
        state_card = wait_for(lambda: inspect(f'{state.lower()}-card.json'), lambda data: expected in json.dumps(data))
        assert 'FIXTURE' in json.dumps(state_card)
        time.sleep(0.5)
        state_card = inspect(f'{state.lower()}-card.json')
        window = next(w for w in state_card['windows'] if w['kCGWindowBounds']['Height'] > 100)
        marker = next(e for e in state_card['elements'] if e.get('AXIdentifier') == 'vikingbar.fixtureMarker')
        assert marker['frame'][0][1] >= window['kCGWindowBounds']['Y'] + 20, 'Fixture header is clipped.'
        peek(['see', '--window-id', str(window['kCGWindowNumber']), '--no-elements', '--no-remote',
              '--path', str(PROOF / f'{state.lower()}.png')], f'{state.lower()}-image.json')
    assert process.poll() is None, 'App exited during proof.'
    (PROOF / 'result.json').write_text(json.dumps({'passed': True, 'features': ['data card', 'five fixture states']}, indent=2))
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
    if process is not None:
        app_log.close()
        (PROOF / 'cleanup.json').write_text(json.dumps({'pid': process.pid, 'exited': process.poll() is not None}))
    print(f'Proof retained at {PROOF}')

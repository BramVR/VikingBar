#!/usr/bin/env python3
"""Build and drive the actual fixture app; retain receipts after process cleanup."""
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / '.build/proof' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
PROOF.mkdir(parents=True)
SETTINGS = PROOF / 'settings.json'
PB = os.environ.get('PEEKABOO_BIN') or shutil.which('peekaboo')
if not PB:
    raise SystemExit('Peekaboo 4 is required. See docs/development.md.')
STATES = {
    'Finite': ('36 GB', ['36.00 GB', '14.00 GB used', '28% used', 'Expires', 'Last updated']),
    'Unlimited': ('Unlimited', ['Unlimited allowance', 'Last updated']),
    'Exhausted': ('0 GB', ['Data exhausted', '0.00 GB', '100% used', 'Last updated']),
    'Stale': ('36 GB', ['36.00 GB', 'Showing an older balance', 'Stale', 'Last updated']),
    'Error': ('Unavailable', ['Unavailable', 'Could not load the example balance', 'No successful update']),
    'Not connected': ('Unavailable', ['No account connected', 'Unavailable', 'Not connected']),
}
process = None
app_log = None
launches = []
coverage = []
icon_width = None


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
    assert process.poll() is None, 'App exited during proof.'
    return json.loads(run([str(ROOT / '.build/inspect-ui'), str(process.pid)], name))


def element(data, identifier):
    return next((e for e in data['elements'] if e.get('AXIdentifier') == identifier), {})


def visible_status(data):
    status = element(data, 'vikingbar.status')
    if not status:
        return False
    (x, y), (width, height) = status['frame']
    return width > 0 and height > 0 and any(
        x >= screen['bounds']['x'] and y >= screen['bounds']['y']
        and x + width <= screen['bounds']['x'] + screen['bounds']['width']
        and y + height <= screen['bounds']['y'] + screen['bounds']['height']
        for screen in screens
    )


def press(selector, name):
    run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'press', selector], f'{name}.json')


def choose_popup(selector, value, name):
    press(selector, f'{name}-picker')
    wait_for(lambda: inspect(f'{name}-menu.json'), lambda d: any(
        e.get('AXRole') == 'AXMenuItem' and e.get('AXTitle') == value for e in d['elements']
    ))
    press(value, f'{name}-select')


def capture_status(data, name):
    assert visible_status(data), 'Status item must be fully within a display.'
    (x, y), (width, height) = element(data, 'vikingbar.status')['frame']
    region = [math.floor(x), math.floor(y), math.ceil(x + width) - math.floor(x),
              math.ceil(y + height) - math.floor(y)]
    peek(['see', '--mode', 'area', '--region', ','.join(map(str, region)), '--retina',
          '--no-elements', '--no-remote', '--path', str(PROOF / f'{name}.png')], f'{name}-image.json')


def popover_window(data):
    popover = next((e for e in data['elements'] if e.get('AXRole') == 'AXPopover'), None)
    if popover is None:
        return None
    (x, y), (width, height) = popover['frame']
    return next((w for w in data['windows'] if all(
        abs(w['kCGWindowBounds'][key] - value) < 1
        for key, value in [('X', x), ('Y', y), ('Width', width), ('Height', height)]
    )), None)


def capture_card(name, fixture=True):
    data = wait_for(lambda: inspect(f'{name}-capture.json'), lambda d: popover_window(d) is not None)
    window = popover_window(data)
    if fixture:
        marker = element(data, 'vikingbar.fixtureMarker')
        assert marker, 'Fixture marker missing.'
        assert marker['frame'][0][1] >= window['kCGWindowBounds']['Y'] + 20, 'Fixture header is clipped.'
    peek(['see', '--window-id', str(window['kCGWindowNumber']), '--no-elements', '--no-remote',
          '--path', str(PROOF / f'{name}.png')], f'{name}-image.json')


def check_status(state, amount, name):
    global icon_width
    title, _ = STATES[state]
    source = 'Not connected' if state == 'Not connected' else f'FIXTURE · {state} · Synthetic data'
    expected_title = title if amount else ''
    data = wait_for(lambda: inspect(f'{name}-status.json'), lambda d:
                    visible_status(d) and element(d, 'vikingbar.status').get('AXTitle') == expected_title
                    and source in element(d, 'vikingbar.status').get('AXDescription', ''))
    assert data['activationPolicy'] == 1, 'App must use accessory policy without a Dock icon.'
    status = element(data, 'vikingbar.status')
    balance = '0.00 GB' if state == 'Exhausted' else '36.00 GB' if state in ('Finite', 'Stale') else title
    for key in ('AXDescription', 'AXHelp'):
        label = status.get(key, '')
        assert source in label and balance in label, f'{key} lacks allowance or provenance: {label}'
        freshness = 'No successful update' if state in ('Error', 'Not connected') else 'Last updated'
        assert freshness in label, f'{key} lacks freshness.'
        if state == 'Stale':
            assert 'Stale' in label, f'{key} lacks stale warning.'
        if state == 'Not connected':
            assert 'FIXTURE' not in label, f'{key} retains fixture provenance.'
    width = status['frame'][1][0]
    if not amount:
        if icon_width is None:
            icon_width = width
        assert width == icon_width, f'Icon-only width changed: {width} != {icon_width}'
    capture_status(data, f'{name}-status')
    return data


def open_card(name):
    observed = wait_for(lambda: inspect(f'{name}-before.json'), visible_status)
    capture_status(observed, f'{name}-before')
    press('vikingbar.status', f'{name}-click')
    return wait_for(lambda: inspect(f'{name}-card.json'), lambda d: bool(element(d, 'vikingbar.remaining')))


def select_state(state, amount, name):
    choose_popup('vikingbar.fixturePicker', state, name)
    expected = STATES[state][1]
    data = wait_for(lambda: inspect(f'{name}-card.json'),
                    lambda d: all(label in json.dumps(d) for label in expected)
                    and ('Not connected' in json.dumps(element(d, 'vikingbar.source'))
                         if state == 'Not connected' else
                         f'FIXTURE · {state} · Synthetic data' in json.dumps(element(d, 'vikingbar.source'), ensure_ascii=False)))
    if state == 'Not connected':
        assert not element(data, 'vikingbar.fixtureMarker'), 'Not connected retains fixture marker.'
    check_status(state, amount, name)
    capture_card(name, fixture=state != 'Not connected')
    if name == 'icon-finite':
        shutil.copyfile(PROOF / f'{name}.png', PROOF / 'card.png')
    coverage.append({'state': state, 'mode': 'amount' if amount else 'iconOnly', 'capture': f'{name}-status.png'})


def direct_connection_choices():
    select_state('Not connected', False, 'direct-disconnected')
    press('vikingbar.connect.direct', 'direct-open')
    data = wait_for(lambda: inspect('direct-form.json'),
                    lambda d: bool(element(d, 'vikingbar.connect.password')))
    for identifier in ('client-id', 'username', 'password', 'submit', 'cancel'):
        assert element(data, 'vikingbar.connect.' + identifier), 'Direct form control missing.'
    assert element(data, 'vikingbar.connect.password').get('AXSubrole') == 'AXSecureTextField'
    press('vikingbar.connect.submit', 'direct-empty-submit')
    data = wait_for(lambda: inspect('direct-validation.json'), lambda d:
                    element(d, 'vikingbar.connect.error').get('messageCode') == 'required-fields')
    assert element(data, 'vikingbar.connect.password').get('valueEmpty') is True
    payload = json.dumps({'client_id': 'synthetic-public-client', 'username': 'synthetic@example.invalid',
                          'password': 'synthetic-only'}).encode()
    result = subprocess.run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'fill-direct'],
                            input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False)
    assert result.returncode == 0 and result.stdout.strip() == b'{"filled":true}', 'Synthetic form fill failed.'
    press('vikingbar.connect.submit', 'direct-fixture-submit')
    wait_for(lambda: inspect('direct-fixture-rejected.json'), lambda d:
             element(d, 'vikingbar.connect.error').get('messageCode') == 'fixture-direct'
             and element(d, 'vikingbar.connect.password').get('valueEmpty') is True)
    press('vikingbar.connect', 'optional-one-password')
    wait_for(lambda: inspect('optional-fixture-rejected.json'), lambda d:
             element(d, 'vikingbar.connect.error').get('messageCode') == 'fixture-one-password')
    result = subprocess.run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'fill-direct'],
                            input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False)
    assert result.returncode == 0 and result.stdout.strip() == b'{"filled":true}', 'Synthetic form refill failed.'
    wait_for(lambda: inspect('direct-before-cancel.json'), lambda d:
             element(d, 'vikingbar.connect.password').get('valueEmpty') is False)
    press('vikingbar.connect.cancel', 'direct-cancel')
    wait_for(lambda: inspect('direct-cancelled.json'), lambda d: not element(d, 'vikingbar.connect.password'))
    press('vikingbar.connect.direct', 'direct-reopen')
    data = wait_for(lambda: inspect('direct-reopened.json'), lambda d: bool(element(d, 'vikingbar.connect.password')))
    assert element(data, 'vikingbar.connect.password').get('valueEmpty') is True
    press('vikingbar.connect.cancel', 'direct-recancel')
    children = subprocess.run(['pgrep', '-P', str(process.pid)], capture_output=True, timeout=5, check=False)
    assert children.returncode == 1 and not children.stdout.strip(), 'Fixture connection launched a child process.'
    select_state('Finite', False, 'direct-return-finite')


def settings_toggle(expected, name, change=False):
    press('Settings', f'{name}-settings-tab')
    data = wait_for(lambda: inspect(f'{name}-settings.json'), lambda d: bool(element(d, 'vikingbar.showRemainingGB')))
    expected_before = not expected if change else expected
    assert element(data, 'vikingbar.showRemainingGB').get('AXValue') == str(int(expected_before))
    text = json.dumps(data)
    for label in ['Show remaining GB in menu bar', 'Display the data left in GB beside the helmet.']:
        assert label in text, f'Missing Settings copy: {label}'
    if change:
        press('vikingbar.showRemainingGB', f'{name}-toggle')
        data = wait_for(lambda: inspect(f'{name}-settings.json'), lambda d:
                        element(d, 'vikingbar.showRemainingGB').get('AXValue') == str(int(expected)))
    check_status('Finite', expected, name)
    assert 'FIXTURE' in json.dumps(element(data, 'vikingbar.fixtureMarker')), 'Settings lacks fixture provenance.'
    capture_card(f'{name}-settings')
    press('Data', f'{name}-data-tab')
    wait_for(lambda: inspect(f'{name}-data.json'), lambda d: bool(element(d, 'vikingbar.remaining')))


def launch(name):
    global process, app_log
    assert process is None or process.poll() is not None, 'Previous task-owned app is still running.'
    process = None
    executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    arguments = ['--fixture', 'finite', '--settings-file', str(SETTINGS)]
    app_log = (PROOF / f'{name}-app.log').open('w')
    process = subprocess.Popen([str(executable), *arguments], cwd=ROOT, stdout=app_log, stderr=subprocess.STDOUT)
    receipt = {'launch': name, 'pid': process.pid, 'parentPID': os.getpid(), 'bundle': str(bundle),
               'executable': str(executable), 'executableSHA256': executable_hash,
               'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'arguments': arguments}
    launches.append(receipt)
    (PROOF / f'{name}-process.json').write_text(json.dumps(receipt, indent=2))
    if name == 'default':
        (PROOF / 'process.json').write_text(json.dumps(receipt, indent=2))
    identity = run(['ps', '-p', str(process.pid), '-o', 'pid=,ppid=,lstart=,command='], f'{name}-process.txt')
    assert str(executable) in identity and identity.split()[:2] == [str(process.pid), str(os.getpid())]
    check_status('Finite', name == 'persist-on', name)
    open_card(name)
    if name == 'default':
        shutil.copyfile(PROOF / 'default-before.png', PROOF / 'before.png')
        shutil.copyfile(PROOF / 'default-click.json', PROOF / 'click.json')


def quit_app(name):
    press('vikingbar.quit', f'{name}-quit')
    assert process.wait(timeout=10) == 0, 'Quit did not exit successfully.'
    launches[-1].update(exited=True, returncode=process.returncode, quitVerified=True)
    app_log.close()
    (PROOF / f'{name}-cleanup.json').write_text(json.dumps(launches[-1], indent=2))


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
    screens = peek(['screen', 'list'], 'screens.json')['screens']
    assert not SETTINGS.exists(), 'Default proof requires a new isolated store.'
    launch('default')
    settings_toggle(False, 'default')
    direct_connection_choices()
    for state in STATES:
        select_state(state, False, f'icon-{state.lower().replace(" ", "-")}')
    select_state('Finite', False, 'icon-return-finite')
    settings_toggle(True, 'enable', change=True)
    for state in STATES:
        select_state(state, True, f'amount-{state.lower().replace(" ", "-")}')
    select_state('Finite', True, 'amount-return-finite')
    for current, target, expected in [('GB', 'GiB', ['33.53 GiB', '13.04 GiB used', 'GiB uses binary units']),
                                      ('GiB', 'GB', ['36.00 GB', '14.00 GB used', 'GB uses decimal units'])]:
        choose_popup(current, target, f'units-{target}')
        data = wait_for(lambda: inspect(f'units-{target}.json'), lambda d: all(s in json.dumps(d) for s in expected))
        status = element(data, 'vikingbar.status')
        assert status.get('AXTitle') == '36 GB', 'Menu amount must remain decimal GB.'
        capture_status(data, f'units-{target}-status')
        capture_card(f'units-{target}')
    assert SETTINGS.is_file(), 'Settings were not saved to the isolated store.'
    quit_app('default')
    launch('persist-on')
    settings_toggle(True, 'persist-on')
    settings_toggle(False, 'disable', change=True)
    quit_app('persist-on')
    launch('persist-off')
    settings_toggle(False, 'persist-off')
    quit_app('persist-off')
finally:
    if process is not None:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        launches[-1].update(exited=process.poll() is not None, returncode=process.returncode)
        (PROOF / f'{launches[-1]["launch"]}-cleanup.json').write_text(json.dumps(launches[-1], indent=2))
    if app_log is not None:
        app_log.close()
    (PROOF / 'cleanup.json').write_text(json.dumps({'pid': process.pid if process is not None else None,
                                                   'exited': all(p.get('exited') for p in launches),
                                                   'processes': launches}, indent=2))
    print(f'Proof retained at {PROOF}')

assert len(launches) == 3 and all(p.get('quitVerified') for p in launches)
(PROOF / 'result.json').write_text(json.dumps({
    'passed': True, 'features': ['data card', 'five fixture states', 'Not connected', 'Settings toggle',
                               'GB/GiB units', 'Quit', 'isolated persistence', 'status captures',
                               'direct form validation and cancellation', 'optional 1Password fixture rejection'],
    'modes': ['iconOnly', 'amount'], 'coverage': coverage, 'iconOnlyWidth': icon_width,
    'persistence': {'default': False, 'relaunchOn': True, 'relaunchOff': False, 'settingsFile': str(SETTINGS)},
    'visualInspection': 'Status crops retained for native appearance inspection; no raster comparison performed.',
}, indent=2))

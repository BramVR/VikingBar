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
    'Finite': ('36 GB', ['36.00 GB', '14.00 GB used', '72% remaining', 'Expires', 'Last updated']),
    'Unlimited': ('Unlimited', ['Unlimited allowance', 'Last updated']),
    'Exhausted': ('0 GB', ['Data exhausted', '0.00 GB', '0% remaining', 'Last updated']),
    'Stale': ('36 GB', ['36.00 GB', 'Showing an older balance', 'Stale', 'Last updated']),
    'Error': ('Unavailable', ['Unavailable', 'Could not load the example balance', 'No successful update']),
    'Not connected': ('Unavailable', ['No account connected', 'Not connected']),
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
    open_settings(name)
    choose_popup('vikingbar.fixturePicker', state, name)
    back_to_balance(name)
    expected = STATES[state][1]
    data = wait_for(lambda: inspect(f'{name}-card.json'),
                    lambda d: all(label in json.dumps(d) for label in expected)
                    and ('Not connected' in json.dumps(element(d, 'vikingbar.source'))
                         if state == 'Not connected' else
                         f'FIXTURE · {state} · Synthetic data' in json.dumps(element(d, 'vikingbar.source'), ensure_ascii=False)))
    assert element(data, 'vikingbar.fixtureMarker'), 'Synthetic launch provenance missing.'
    check_status(state, amount, name)
    capture_card(name)
    if name == 'icon-finite':
        shutil.copyfile(PROOF / f'{name}.png', PROOF / 'card.png')
    coverage.append({'state': state, 'mode': 'amount' if amount else 'iconOnly', 'capture': f'{name}-status.png'})


def open_settings(name):
    press('vikingbar.settings', f'{name}-settings')
    wait_for(lambda: inspect(f'{name}-settings-ready.json'),
             lambda d: bool(element(d, 'vikingbar.showRemainingGB')))


def back_to_balance(name):
    press('vikingbar.back', f'{name}-back')
    return wait_for(lambda: inspect(f'{name}-balance-ready.json'),
                    lambda d: bool(element(d, 'vikingbar.settings')))


def settings_toggle(expected, name, change=False):
    open_settings(name)
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
    back_to_balance(name)


def check_layout(name):
    data = inspect(f'{name}-layout.json')
    identifiers = [e.get('AXIdentifier') for e in data['elements']]
    assert identifiers.count('vikingbar.settings') == 1, 'Balance needs exactly one Settings entry.'
    assert 'vikingbar.fixturePicker' not in identifiers, 'Fixture picker belongs in Settings.'
    assert 'vikingbar.units' not in identifiers, 'Data units belong in Settings.'
    assert not any(e.get('AXRole') == 'AXTabGroup' for e in data['elements']), 'Old tab shell remains.'
    window = popover_window(data)
    assert window, 'Balance popover missing.'
    bounds = window['kCGWindowBounds']
    previous_y = bounds['Y']
    for identifier in ['vikingbar.subscriptionPicker', 'vikingbar.bundlePicker', 'vikingbar.remaining',
                       'vikingbar.bundleDetails', 'vikingbar.refresh', 'vikingbar.openMyViking',
                       'vikingbar.settings']:
        item = element(data, identifier)
        assert item, f'Missing balance control {identifier}.'
        (x, y), (width, height) = item['frame']
        assert y >= previous_y, f'Approved order violated at {identifier}.'
        assert x >= bounds['X'] and y >= bounds['Y'] and width > 0 and height > 0
        assert x + width <= bounds['X'] + bounds['Width'] + 1
        assert y + height <= bounds['Y'] + bounds['Height'] + 1, f'Clipped control {identifier}.'
        previous_y = y


def selection_and_refresh():
    for selector, value, amount, total in [
        ('vikingbar.bundlePicker', 'Extra data', '4.00 GB', '5.00 GB'),
        ('vikingbar.subscriptionPicker', 'Travel SIM', '8.00 GB', '10.00 GB'),
        ('vikingbar.bundlePicker', 'Extra data', '1.00 GB', '2.00 GB'),
        ('vikingbar.subscriptionPicker', 'Example SIM', '36.00 GB', '50.00 GB'),
    ]:
        name = f'selection-{value.lower().replace(" ", "-")}-{amount.split(".")[0]}'
        choose_popup(selector, value, name)
        data = wait_for(lambda: inspect(f'{name}.json'), lambda d:
                        amount in json.dumps(element(d, 'vikingbar.remaining')) and total in json.dumps(d))
        assert value in json.dumps(data), 'Selection identity missing.'
        capture_card(name)
        open_settings(name)
        back_to_balance(name)
        assert amount in json.dumps(element(inspect(f'{name}-return.json'), 'vikingbar.remaining'))
    press('vikingbar.bundleDetails', 'details-expand')
    wait_for(lambda: inspect('details.json'), lambda d: 'Extra charges' in json.dumps(d))
    capture_card('bundle-details')
    press('vikingbar.bundleDetails', 'details-collapse')
    before = json.dumps(element(inspect('refresh-before.json'), 'vikingbar.freshness'))
    press('vikingbar.refresh', 'refresh')
    refreshing = wait_for(lambda: inspect('refreshing.json'), lambda d: 'Refreshing' in json.dumps(d))
    assert element(refreshing, 'vikingbar.refresh').get('AXEnabled') in (False, 'false', '0', 0)
    assert element(refreshing, 'vikingbar.subscriptionPicker').get('AXEnabled') in (False, 'false', '0', 0)
    capture_card('refreshing')
    wait_for(lambda: inspect('refreshed.json'), lambda d:
             'Refreshing' not in json.dumps(d)
             and json.dumps(element(d, 'vikingbar.freshness')) != before)
    capture_card('refreshed')
    press('vikingbar.points', 'points-open')
    wait_for(lambda: inspect('points.json'), lambda d: bool(element(d, 'vikingbar.points.customerLabel')))
    capture_card('points', fixture=False)
    back_to_balance('points')
    coverage.append({'scenario': 'SIM and bundle selection, Settings return, refresh, details, Points'})


def launch(name, appearance='light', reduce_transparency=False):
    global process, app_log
    assert process is None or process.poll() is not None, 'Previous task-owned app is still running.'
    process = None
    executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    arguments = ['--fixture', 'finite', '--settings-file', str(SETTINGS),
                 '--fixture-appearance', appearance]
    if reduce_transparency:
        arguments.append('--fixture-reduce-transparency')
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
    check_layout(name)
    capture_card(f'{name}-balance')
    if name == 'default':
        shutil.copyfile(PROOF / 'default-before.png', PROOF / 'before.png')
        shutil.copyfile(PROOF / 'default-click.json', PROOF / 'click.json')


def quit_app(name):
    open_settings(f'{name}-quit')
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
    for state in STATES:
        select_state(state, False, f'icon-{state.lower().replace(" ", "-")}')
    select_state('Finite', False, 'icon-return-finite')
    settings_toggle(True, 'enable', change=True)
    for state in STATES:
        select_state(state, True, f'amount-{state.lower().replace(" ", "-")}')
    select_state('Finite', True, 'amount-return-finite')
    for current, target, expected in [('GB', 'GiB', ['33.53 GiB', '13.04 GiB used', 'GiB uses binary units']),
                                      ('GiB', 'GB', ['36.00 GB', '14.00 GB used', 'GB uses decimal units'])]:
        open_settings(f'units-{target}')
        choose_popup('vikingbar.units', target, f'units-{target}')
        wait_for(lambda: inspect(f'units-{target}-settings.json'),
                 lambda d: expected[-1] in json.dumps(d))
        capture_card(f'units-{target}-settings')
        back_to_balance(f'units-{target}')
        data = wait_for(lambda: inspect(f'units-{target}.json'), lambda d: all(s in json.dumps(d) for s in expected[:-1]))
        status = element(data, 'vikingbar.status')
        assert status.get('AXTitle') == '36 GB', 'Menu amount must remain decimal GB.'
        capture_status(data, f'units-{target}-status')
        capture_card(f'units-{target}')
    selection_and_refresh()
    assert SETTINGS.is_file(), 'Settings were not saved to the isolated store.'
    quit_app('default')
    launch('persist-on', appearance='dark')
    settings_toggle(True, 'persist-on')
    select_state('Error', True, 'dark-error')
    select_state('Finite', True, 'dark-finite')
    settings_toggle(False, 'disable', change=True)
    quit_app('persist-on')
    launch('persist-off', appearance='high-contrast-light')
    settings_toggle(False, 'persist-off')
    quit_app('persist-off')
    launch('contrast-dark', appearance='high-contrast-dark', reduce_transparency=True)
    settings_toggle(False, 'contrast-dark')
    select_state('Error', False, 'contrast-dark-error')
    select_state('Finite', False, 'contrast-dark-finite')
    quit_app('contrast-dark')
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

assert len(launches) == 4 and all(p.get('quitVerified') for p in launches)
(PROOF / 'result.json').write_text(json.dumps({
    'passed': True, 'features': ['data card', 'five fixture states', 'Not connected', 'Settings toggle',
                               'GB/GiB units', 'Quit', 'isolated persistence', 'status captures',
                               'SIM and bundle selection', 'refresh', 'details', 'Points navigation',
                               'light and dark', 'high contrast', 'reduced transparency'],
    'modes': ['iconOnly', 'amount'], 'coverage': coverage, 'iconOnlyWidth': icon_width,
    'persistence': {'default': False, 'relaunchOn': True, 'relaunchOff': False, 'settingsFile': str(SETTINGS)},
    'visualInspection': 'Status crops retained for native appearance inspection; no raster comparison performed.',
}, indent=2))

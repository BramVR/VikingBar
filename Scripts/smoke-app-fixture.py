#!/usr/bin/env python3
"""Build and drive the actual fixture app; retain receipts after process cleanup."""
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
UI_SPEC = importlib.util.spec_from_file_location('native_ui_proof', ROOT / 'Scripts/native-ui-proof.py')
UI = importlib.util.module_from_spec(UI_SPEC)
UI_SPEC.loader.exec_module(UI)
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
    return UI.visible_status(data, screens)


def press(selector, name):
    run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'press', selector], f'{name}.json')


def validate_pointer_receipt(receipt, action, selector, normalized, target_frame):
    assert receipt.get(action) == selector, f'{action} receipt targets the wrong control.'
    assert receipt.get('pid') == process.pid, f'{action} receipt uses the wrong process.'
    assert receipt.get('normalized') == list(normalized), f'{action} receipt uses the wrong point.'
    assert receipt.get('frame') == target_frame, f'{action} receipt frame changed before dispatch.'
    x, y = receipt['destination']
    (left, top), (width, height) = target_frame
    assert left < x < left + width and top < y < top + height, f'{action} destination is outside the control.'


def pointer_action(action, selector, name, x=0.5, y=0.5, target_frame=None):
    if target_frame is None:
        target_frame = element(inspect(f'{name}-target.json'), selector)['frame']
    output = run([str(ROOT / '.build/inspect-ui'), str(process.pid), action, selector, str(x), str(y)],
                 f'{name}.json')
    receipt = json.loads(output)
    validate_pointer_receipt(receipt, action + 'ed', selector, (x, y), target_frame)
    return receipt


def hover(selector, name, x=0.5, y=0.5, target_frame=None):
    return pointer_action('hover', selector, name, x, y, target_frame)


def click(selector, name, x=0.5, y=0.5, target_frame=None):
    return pointer_action('click', selector, name, x, y, target_frame)


def choose_popup(selector, value, name):
    run([str(ROOT / '.build/inspect-ui'), str(process.pid), 'choose', selector, value], f'{name}-choose.json')


def capture_status(data, name):
    assert visible_status(data), 'Status item must be fully within a display.'
    (x, y), (width, height) = element(data, 'vikingbar.status')['frame']
    region = [math.floor(x), math.floor(y), math.ceil(x + width) - math.floor(x),
              math.ceil(y + height) - math.floor(y)]
    peek(['see', '--mode', 'area', '--region', ','.join(map(str, region)), '--retina',
          '--no-elements', '--no-remote', '--path', str(PROOF / f'{name}.png')], f'{name}-image.json')


def popover_window(data):
    try:
        _, window = UI.popover_window(data, screens)
        return window
    except UI.UIFailure:
        return None


def capture_card(name, fixture=True):
    stability = UI.CapturePopoverStability()
    settled = None

    def ready(data):
        nonlocal settled

        def qualifies(boundary, window):
            if not fixture:
                return True
            marker = element(data, 'vikingbar.fixtureMarker')
            return (UI.contained(marker, boundary)
                    and marker['frame'][0][1] >= window['kCGWindowBounds']['Y'] + 20)

        settled = stability.observe(data, screens, process.pid, qualifies)
        return settled is not None

    data = wait_for(lambda: inspect(f'{name}-capture.json'), ready)
    boundary, window = settled
    if fixture:
        marker = element(data, 'vikingbar.fixtureMarker')
        assert marker, 'Fixture marker missing.'
        assert UI.contained(marker, boundary), 'Fixture marker is clipped.'
        assert marker['frame'][0][1] >= window['kCGWindowBounds']['Y'] + 20, 'Fixture header is clipped.'

    def invoke(arguments):
        return json.loads(run(arguments, f'{name}-image.json'))

    UI.capture_exact_window(PB, process.pid, window['kCGWindowNumber'], PROOF / f'{name}.png', invoke)


def control_geometry(data, selector):
    target = element(data, selector)
    assert target, f'Missing pointer target {selector}.'
    boundary, window = UI.popover_window(data, screens)
    assert UI.contained(target, boundary), f'Pointer target {selector} is clipped.'
    return target['frame'], window['kCGWindowBounds']


def enabled_state(target):
    value = target.get('AXEnabled')
    assert value in (True, False, 'true', 'false', '1', '0', 1, 0), 'Control has no declared enabled state.'
    return value in (True, 'true', '1', 1)


def hover_triplet(selector, exit_selector, name, *, enabled=True, x=0.5, y=0.5):
    prime = inspect(f'{name}-prime.json')
    reset_frame, _ = control_geometry(prime, 'vikingbar.fixtureMarker')
    reset_receipt = hover('vikingbar.fixtureMarker', f'{name}-reset-receipt', target_frame=reset_frame)
    normal = inspect(f'{name}-normal.json')
    frame, window = control_geometry(normal, selector)
    assert enabled_state(element(normal, selector)) is enabled, f'Unexpected enabled state for {selector}.'
    capture_card(f'{name}-normal')
    hover_receipt = hover(selector, f'{name}-hover-receipt', x, y, frame)
    hovered = inspect(f'{name}-hovered.json')
    assert control_geometry(hovered, selector) == (frame, window), f'Hover changed geometry for {selector}.'
    assert enabled_state(element(hovered, selector)) is enabled, f'Hover changed enabled state for {selector}.'
    capture_card(f'{name}-hover')
    exit_frame, _ = control_geometry(hovered, exit_selector)
    exit_receipt = hover(exit_selector, f'{name}-exit-receipt', target_frame=exit_frame)
    exited = inspect(f'{name}-exited.json')
    assert control_geometry(exited, selector) == (frame, window), f'Pointer exit changed geometry for {selector}.'
    assert enabled_state(element(exited, selector)) is enabled, f'Pointer exit changed enabled state for {selector}.'
    capture_card(f'{name}-exit')
    coverage.append({
        'scenario': 'menu action hover', 'appearance': launches[-1]['appearance'], 'selector': selector,
        'exitSelector': exit_selector, 'enabled': enabled, 'normalized': [x, y],
        'captures': [f'{name}-normal.png', f'{name}-hover.png', f'{name}-exit.png'],
        'receipts': [f'{name}-reset-receipt.json', f'{name}-hover-receipt.json', f'{name}-exit-receipt.json'],
        'frameStable': True, 'windowStable': True,
        'resetDestination': reset_receipt['destination'], 'hoverDestination': hover_receipt['destination'],
        'exitDestination': exit_receipt['destination'],
    })


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


def connected_account_summary():
    select_state('Finite', False, 'account-preview-balance')
    press('vikingbar.settings', 'account-settings')
    press('vikingbar.connect.direct', 'account-open')
    data = wait_for(lambda: inspect('account-summary.json'),
                    lambda d: bool(element(d, 'vikingbar.account.status')))
    assert 'Mobile Vikings' in json.dumps(element(data, 'vikingbar.account.status'))
    assert not element(data, 'vikingbar.account.method')
    assert not element(data, 'vikingbar.account.client-id')
    assert 'alex@example.invalid' in json.dumps(element(data, 'vikingbar.account.username'))
    assert not element(data, 'vikingbar.connect.password'), 'Summary exposed a credential form.'
    capture_card('account-summary', fixture=False)
    press('vikingbar.account.change', 'account-change')
    data = wait_for(lambda: inspect('account-change-form.json'),
                    lambda d: bool(element(d, 'vikingbar.connect.password')))
    assert element(data, 'vikingbar.connect.password').get('valueEmpty') is True
    assert element(data, 'vikingbar.connect.client-id').get('valueEmpty') is False
    assert element(data, 'vikingbar.connect.username').get('valueEmpty') is False
    press('vikingbar.connect.cancel', 'account-change-cancel')
    wait_for(lambda: inspect('account-returned.json'),
             lambda d: bool(element(d, 'vikingbar.account.status')) and not element(d, 'vikingbar.connect.password'))
    press('vikingbar.back', 'account-back-settings')
    press('vikingbar.back', 'account-back-balance')


def direct_connection_choices():
    select_state('Not connected', False, 'direct-disconnected')
    press('vikingbar.connect.direct', 'direct-open')
    data = wait_for(lambda: inspect('direct-form.json'),
                    lambda d: bool(element(d, 'vikingbar.connect.password')))
    for identifier in ('client-id', 'username', 'password', 'submit', 'cancel'):
        assert element(data, 'vikingbar.connect.' + identifier), 'Direct form control missing.'
    assert element(data, 'vikingbar.connect.password').get('AXSubrole') == 'AXSecureTextField'
    assert element(data, 'vikingbar.connect.password').get('valueEmpty') is True
    capture_card('direct-form-empty', fixture=False)
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
    data = wait_for(lambda: inspect(f'{name}-layout.json'), lambda d: popover_window(d) is not None)
    identifiers = [e.get('AXIdentifier') for e in data['elements']]
    assert identifiers.count('vikingbar.settings') == 1, 'Balance needs exactly one Settings entry.'
    assert 'vikingbar.fixturePicker' not in identifiers, 'Fixture picker belongs in Settings.'
    assert 'vikingbar.units' not in identifiers, 'Data units belong in Settings.'
    assert not any(e.get('AXRole') == 'AXTabGroup' for e in data['elements']), 'Old tab shell remains.'
    window = popover_window(data)
    assert window, 'Balance popover missing.'
    boundary, _ = UI.popover_window(data, screens)
    bounds = window['kCGWindowBounds']
    rows = [
        ['vikingbar.subscriptionPicker'], ['vikingbar.bundlePicker'], ['vikingbar.remaining'],
        ['vikingbar.bundleDetails'], ['vikingbar.refresh', 'vikingbar.openMyViking'],
        ['vikingbar.bills', 'vikingbar.points', 'vikingbar.settings'],
    ]
    previous_center = bounds['Y']
    for row in rows:
        centers = []
        for identifier in row:
            item = element(data, identifier)
            assert item, f'Missing balance control {identifier}.'
            assert UI.contained(item, boundary), f'Clipped or invalid control {identifier}.'
            x, y, width, height = UI.frame(item)
            assert x >= bounds['X'] and y >= bounds['Y'] and width > 0 and height > 0
            assert x + width <= bounds['X'] + bounds['Width'] + 1
            assert y + height <= bounds['Y'] + bounds['Height'] + 1, f'Clipped control {identifier}.'
            centers.append(y + height / 2)
        assert max(centers) - min(centers) <= 2, f'Controls do not share a logical row: {row}.'
        center = sum(centers) / len(centers)
        assert center > previous_center, f'Approved row order violated at {row}.'
        previous_center = center


def prove_light_hover_actions():
    hover_triplet('vikingbar.refresh', 'vikingbar.source', 'light-refresh')
    hover_triplet('vikingbar.openMyViking', 'vikingbar.source', 'light-open-my-viking', x=0.95)
    hover_triplet('vikingbar.bills', 'vikingbar.points', 'light-bills-transfer')
    hover_triplet('vikingbar.points', 'vikingbar.settings', 'light-points-transfer')
    hover_triplet('vikingbar.settings', 'vikingbar.source', 'light-settings')

    settings_frame, _ = control_geometry(inspect('light-settings-edge-before.json'), 'vikingbar.settings')
    receipt = click('vikingbar.settings', 'light-settings-edge-click', x=0.05, target_frame=settings_frame)
    wait_for(lambda: inspect('light-settings-edge-result.json'),
             lambda d: bool(element(d, 'vikingbar.showRemainingGB')))
    coverage.append({
        'scenario': 'near-edge pointer activation', 'appearance': 'light', 'selector': 'vikingbar.settings',
        'normalized': [0.05, 0.5], 'receipt': 'light-settings-edge-click.json',
        'destination': receipt['destination'], 'result': 'Settings shown',
    })
    hover_triplet('vikingbar.back', 'vikingbar.source', 'light-back')
    back_to_balance('light-back')
    prove_disabled_bills('light')


def prove_disabled_bills(name):
    press('vikingbar.bills', f'{name}-bills-open')
    data = wait_for(lambda: inspect(f'{name}-bills-ready.json'),
                    lambda d: bool(element(d, 'vikingbar.invoices.load')))
    assert enabled_state(element(data, 'vikingbar.invoices.load')) is False
    hover_triplet('vikingbar.invoices.load', 'vikingbar.invoices.message', f'{name}-load-bills-disabled',
                  enabled=False)
    back_to_balance(f'{name}-bills')


def prove_appearance_hover(name, selector, x=0.5):
    hover_triplet(selector, 'vikingbar.source', f'{name}-representative', x=x)
    prove_disabled_bills(name)


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
    wait_for(lambda: inspect('details.json'), lambda d: UI.bundle_details_visible(
        d, screens, 'Monthly data', 'Monthly mobile data allowance', 'Mobile data · Domestic and EU roaming'))
    capture_card('bundle-details')
    press('vikingbar.bundleDetails', 'details-collapse')
    wait_for(lambda: inspect('details-collapsed.json'), lambda d: UI.bundle_details_collapsed(d, screens))
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


def launch(name, appearance=None, reduce_transparency=False):
    global process, app_log
    assert process is None or process.poll() is not None, 'Previous task-owned app is still running.'
    process = None
    executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    arguments = ['--fixture', 'finite', '--settings-file', str(SETTINGS)]
    if appearance is not None:
        arguments.extend(['--fixture-appearance', appearance])
    if reduce_transparency:
        arguments.append('--fixture-reduce-transparency')
    app_log = (PROOF / f'{name}-app.log').open('w')
    process = subprocess.Popen([str(executable), *arguments], cwd=ROOT, stdout=app_log, stderr=subprocess.STDOUT)
    receipt = {'launch': name, 'appearance': appearance, 'reduceTransparency': reduce_transparency,
               'pid': process.pid, 'parentPID': os.getpid(), 'bundle': str(bundle),
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
    launch('default', appearance='light')
    prove_light_hover_actions()
    settings_toggle(False, 'default')
    connected_account_summary()
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
    prove_appearance_hover('dark', 'vikingbar.refresh')
    settings_toggle(True, 'persist-on')
    select_state('Error', True, 'dark-error')
    select_state('Finite', True, 'dark-finite')
    settings_toggle(False, 'disable', change=True)
    quit_app('persist-on')
    launch('persist-off', appearance='high-contrast-light')
    prove_appearance_hover('high-contrast-light', 'vikingbar.openMyViking', x=0.05)
    settings_toggle(False, 'persist-off')
    quit_app('persist-off')
    launch('contrast-dark', appearance='high-contrast-dark', reduce_transparency=True)
    prove_appearance_hover('high-contrast-dark', 'vikingbar.settings')
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
                               'connected account summary and change cancellation', 'direct form validation and cancellation', 'optional 1Password fixture rejection',
                               'SIM and bundle selection', 'refresh', 'details', 'Points navigation',
                               'menu action hover and pointer activation', 'disabled Bills action',
                               'light and dark', 'high contrast', 'reduced transparency'],
    'modes': ['iconOnly', 'amount'], 'coverage': coverage, 'iconOnlyWidth': icon_width,
    'persistence': {'default': False, 'relaunchOn': True, 'relaunchOff': False, 'settingsFile': str(SETTINGS)},
    'visualInspection': 'Native normal, hover, and exit captures retained for manual appearance inspection; '
                        'no raster comparison performed.',
}, indent=2))

import ast
import subprocess
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest


class InspectUIResolutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="vikingbar-resolution-")
        cls.addClassCleanup(cls.directory.cleanup)
        source = Path(__file__).resolve().parents[1] / "inspect-ui.swift"
        prefix = source.read_text().split("let arguments =", 1)[0]
        harness = Path(cls.directory.name) / "resolution.swift"
        harness.write_text(prefix + r'''
struct DispatchFailure: Error {}
struct Match {
    let id: Int
    let role: String?
    let enabled: Bool
}
let scenario = CommandLine.arguments[1]
var tick: TimeInterval = 0
var resolutions = 0
var actions: [Int] = []
func run<T>(_ resolve: () throws -> T?, _ perform: (T) throws -> Void) throws {
    try resolveAndPerform(timeout: 2, now: { tick }, pause: { tick += 0.5 }, resolve: {
        resolutions += 1
        return try resolve()
    }, perform: perform)
}
switch scenario {
case "delayed":
    try run({ resolutions < 3 ? nil : 42 }, { actions.append($0) })
    precondition(resolutions == 3 && actions == [42])
case "timeout":
    do {
        try run({ nil }, { actions.append($0) })
        fatalError("Missing target did not time out")
    } catch ResolutionFailure.timeout {}
    precondition(actions.isEmpty && resolutions > 0 && tick <= 2.5)
case "late":
    do {
        try run({ tick = 5; return 42 }, { actions.append($0) })
        fatalError("Late resolution dispatched an action")
    } catch ResolutionFailure.timeout {}
    precondition(resolutions == 1 && actions.isEmpty)
case "duplicate":
    do {
        try run({ try uniqueTarget([11, 22]) }, { actions.append($0) })
        fatalError("Distinct matching controls were accepted")
    } catch ResolutionFailure.ambiguous {}
    precondition(actions.isEmpty && resolutions == 1)
case "inherited-scroll-identifier":
    let matches = [Match(id: 11, role: "AXDisclosureTriangle", enabled: true),
                   Match(id: 12, role: "AXScrollArea", enabled: false)]
    try run({ try uniqueNonScrollTarget(matches, role: { $0.role }) }, { actions.append($0.id) })
    precondition(actions == [11] && resolutions == 1)
case "scroll-only":
    let matches = [Match(id: 12, role: "AXScrollArea", enabled: false)]
    do {
        try run({ try uniqueNonScrollTarget(matches, role: { $0.role }) }, { actions.append($0.id) })
        fatalError("Inert scroll area was pressed")
    } catch ResolutionFailure.timeout {}
    precondition(actions.isEmpty && resolutions > 0)
case "duplicate-disclosures":
    let matches = [Match(id: 11, role: "AXDisclosureTriangle", enabled: true),
                   Match(id: 12, role: "AXScrollArea", enabled: false),
                   Match(id: 13, role: "AXDisclosureTriangle", enabled: false)]
    do {
        try run({ try uniqueNonScrollTarget(matches, role: { $0.role }) }, { actions.append($0.id) })
        fatalError("Distinct disclosure controls were accepted")
    } catch ResolutionFailure.ambiguous {}
    precondition(actions.isEmpty && resolutions == 1)
case "unknown-role":
    let matches = [Match(id: 11, role: "AXDisclosureTriangle", enabled: true),
                   Match(id: 14, role: nil, enabled: false)]
    do {
        try run({ try uniqueNonScrollTarget(matches, role: { $0.role }) }, { actions.append($0.id) })
        fatalError("Unknown-role candidate was silently discarded")
    } catch ResolutionFailure.ambiguous {}
    precondition(actions.isEmpty && resolutions == 1)
case "success":
    try run({ try uniqueTarget([7]) }, { actions.append($0) })
    precondition(resolutions == 1 && actions == [7])
case "uncertain":
    do {
        try run({ 9 }, { value in actions.append(value); throw DispatchFailure() })
        fatalError("Uncertain dispatch was swallowed")
    } catch is DispatchFailure {}
    precondition(resolutions == 1 && actions == [9])
case "readiness":
    try run({ readyTarget(12, visible: resolutions > 1, enabled: resolutions > 2) }, { actions.append($0) })
    precondition(resolutions == 3 && actions == [12])
case "unavailable":
    do {
        try run({ throw ResolutionFailure.unavailable }, { actions.append($0) })
        fatalError("Terminal resolver failure was swallowed")
    } catch ResolutionFailure.unavailable {}
    precondition(resolutions == 1 && actions.isEmpty)
case "geometry":
    precondition(isFinitePositiveRectangle(CGRect(x: 0, y: 0, width: 360, height: 680)))
    for width in [CGFloat.zero, -1, .infinity, .nan] {
        precondition(!isFinitePositiveRectangle(CGRect(x: 0, y: 0, width: width, height: 20)))
    }
    precondition(!isFinitePositiveRectangle(CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                                                 width: CGFloat.greatestFiniteMagnitude, height: 20)))
default:
    fatalError("Unknown test")
}
print("passed " + scenario)
''')
        cls.executable = Path(cls.directory.name) / "resolution"
        result = subprocess.run(["swiftc", str(harness), "-o", str(cls.executable)],
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def verify(self, scenario):
        result = subprocess.run([str(self.executable), scenario], cwd=self.directory.name,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("passed " + scenario, result.stdout)

    def test_target_appearing_during_bound_is_resolved_and_pressed_in_same_call(self):
        self.verify("delayed")

    def test_missing_target_times_out_without_dispatch(self):
        self.verify("timeout")

    def test_late_resolution_never_dispatches(self):
        self.verify("late")

    def test_distinct_matching_controls_fail_without_dispatch(self):
        self.verify("duplicate")

    def test_inherited_scroll_identifier_does_not_make_disclosure_ambiguous(self):
        self.verify("inherited-scroll-identifier")

    def test_scroll_only_match_times_out_without_dispatch(self):
        self.verify("scroll-only")

    def test_distinct_disclosures_remain_ambiguous_when_one_is_disabled(self):
        self.verify("duplicate-disclosures")

    def test_unknown_role_remains_ambiguous(self):
        self.verify("unknown-role")

    def test_successful_dispatch_is_never_retried(self):
        self.verify("success")

    def test_uncertain_dispatch_once(self):
        self.verify("uncertain")

    def test_transitional_visibility_and_enabled_state_wait_before_single_dispatch(self):
        self.verify("readiness")

    def test_terminal_resolver_failure_is_not_retried(self):
        self.verify("unavailable")

    def test_invalid_or_overflowing_geometry_is_rejected(self):
        self.verify("geometry")


class FixturePickerInvocationTests(unittest.TestCase):
    def test_picker_open_and_item_selection_use_one_helper_invocation(self):
        path = Path(__file__).resolve().parents[1] / "smoke-app-fixture.py"
        function = next(node for node in ast.parse(path.read_text()).body
                        if isinstance(node, ast.FunctionDef) and node.name == "choose_popup")
        calls = []
        scope = {"ROOT": Path("/fixture"), "process": SimpleNamespace(pid=123),
                 "run": lambda *args: calls.append(args)}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), "exec"), scope)
        scope["choose_popup"]("vikingbar.fixturePicker", "Finite", "finite")
        self.assertEqual(calls, [(["/fixture/.build/inspect-ui", "123", "choose",
                                  "vikingbar.fixturePicker", "Finite"], "finite-choose.json")])

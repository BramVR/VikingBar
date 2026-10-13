from pathlib import Path
import json
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class InspectUITests(unittest.TestCase):
    def test_snapshot_omits_invalid_frames_and_keeps_semantic_identity(self):
        source = (SCRIPTS / "inspect-ui.swift").read_text().split("let arguments =", 1)[0]
        start = source.index("func attribute(")
        end = source.index("\nfunc children(", start)
        attribute = r'''
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    switch name {
    case "AXIdentifier": return "synthetic-target" as CFString
    case "AXPosition":
        var point = CGPoint(x: scenario == "infinite" ? CGFloat.infinity : 100, y: 20)
        if scenario == "overflow" { point.x = .greatestFiniteMagnitude }
        return AXValueCreate(.cgPoint, &point)
    case "AXSize":
        if scenario == "missing" { return nil }
        var size = CGSize(width: 30, height: 40)
        if scenario == "nan" { size.width = .nan }
        if scenario == "zero" { size.width = 0 }
        if scenario == "overflow" { size.width = .greatestFiniteMagnitude }
        return AXValueCreate(.cgSize, &size)
    default: return nil
    }
}
'''
        harness = source[:start] + attribute + source[end:] + r'''
let scenario = CommandLine.arguments[1]
try writeJSON(record(AXUIElementCreateApplication(getpid())))
'''
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / "SnapshotProbe.swift"
            executable = Path(directory) / "SnapshotProbe"
            swift.write_text(harness)
            compiled = subprocess.run(["swiftc", "-swift-version", "6", str(swift), "-o", str(executable)],
                                      capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            for scenario in ("valid", "infinite", "nan", "zero", "missing", "overflow"):
                with self.subTest(scenario=scenario):
                    result = subprocess.run([str(executable), scenario], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = {"AXIdentifier": "synthetic-target"}
                    if scenario == "valid":
                        expected["frame"] = [[100, 20], [30, 40]]
                    self.assertEqual(json.loads(result.stdout), expected)

    def test_reference_identity_deduplicates_only_the_same_ax_element(self):
        source = (SCRIPTS / "inspect-ui.swift").read_text()
        prefix = source.split("func elements", 1)[0]
        harness = prefix + r'''
@main
struct ReferenceIdentityProbe {
    static func main() {
        let first = AXUIElementCreateApplication(getpid())
        let repeated = AXUIElementCreateApplication(getpid())
        let distinct = AXUIElementCreateApplication(getppid())
        var elements: [AXUIElement] = []
        var depths: [(element: AXUIElement, depth: Int)] = []
        guard recordTraversal(first, depth: 14, elements: &elements, shallowestDepths: &depths),
              recordTraversal(repeated, depth: 2, elements: &elements, shallowestDepths: &depths),
              !recordTraversal(repeated, depth: 2, elements: &elements, shallowestDepths: &depths),
              !recordTraversal(repeated, depth: 3, elements: &elements, shallowestDepths: &depths),
              recordTraversal(distinct, depth: 14, elements: &elements, shallowestDepths: &depths)
        else {
            fatalError("AX traversal depth tracking was not preserved")
        }
        guard elements.count == 2, CFEqual(elements[0], first), CFEqual(elements[1], distinct) else {
            fatalError("AX reference identity was not preserved")
        }
        print("same-reference-deduplicated; shallower-reference-revisited; distinct-reference-retained")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / "ReferenceIdentityProbe.swift"
            executable = Path(directory) / "ReferenceIdentityProbe"
            swift.write_text(harness)
            compiled = subprocess.run(
                ["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(executable)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "same-reference-deduplicated; shallower-reference-revisited; distinct-reference-retained",
        )


if __name__ == "__main__":
    unittest.main()

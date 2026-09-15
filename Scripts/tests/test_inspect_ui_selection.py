import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InspectUISelectionTests(unittest.TestCase):
    def test_duplicate_references_select_one_control_but_distinct_matches_fail(self):
        source = (ROOT / "Scripts/inspect-ui.swift").read_text()
        declarations, separator, _ = source.partition("let arguments = Array(CommandLine.arguments.dropFirst())")
        self.assertTrue(separator)
        with tempfile.TemporaryDirectory(prefix="vikingbar-ax-selection-") as directory:
            script = Path(directory) / "selection.swift"
            script.write_text(declarations + SYNTHETIC_SELECTION)
            executable = Path(directory) / "selection"
            environment = {"PATH": os.defpath, "LC_ALL": "C"}
            result = subprocess.run(["/usr/bin/swiftc", str(script), "-o", str(executable)],
                                    capture_output=True, timeout=60, check=False, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            result = subprocess.run([str(executable)], capture_output=True, timeout=10, check=False, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout.strip(), b"selection-passed")


SYNTHETIC_SELECTION = r'''
let expectedPath = "/checkout/.build/app/VikingBar.app/Contents/MacOS/VikingBarApp"
let expectedBundleID = "be.bram.vikingbar"
do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("VikingBarApp")
    precondition(FileManager.default.createFile(atPath: target.path, contents: Data()))
    let symlink = directory.appendingPathComponent("VikingBarAlias")
    try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let canonicalTarget = canonicalExecutablePath(target.path)
    let canonicalSymlink = canonicalExecutablePath(symlink.path)
    precondition(canonicalSymlink == canonicalTarget)
    precondition(isExpectedProcessIdentity(
        executablePath: canonicalSymlink, expectedExecutablePath: canonicalTarget,
        packagedBundleIdentifier: expectedBundleID, reportedBundleIdentifier: nil
    ))
    precondition(!isExpectedProcessIdentity(
        executablePath: canonicalExecutablePath(directory.appendingPathComponent("unrelated").path),
        expectedExecutablePath: canonicalTarget,
        packagedBundleIdentifier: expectedBundleID, reportedBundleIdentifier: nil
    ))
}
precondition(isExpectedProcessIdentity(
    executablePath: expectedPath, expectedExecutablePath: expectedPath,
    packagedBundleIdentifier: expectedBundleID, reportedBundleIdentifier: nil
))
precondition(isExpectedProcessIdentity(
    executablePath: "/Applications/VikingBar.app/Contents/MacOS/VikingBarApp",
    expectedExecutablePath: expectedPath,
    packagedBundleIdentifier: nil, reportedBundleIdentifier: expectedBundleID
))
precondition(!isExpectedProcessIdentity(
    executablePath: "/other/VikingBarApp", expectedExecutablePath: expectedPath,
    packagedBundleIdentifier: expectedBundleID, reportedBundleIdentifier: nil
))
precondition(!isExpectedProcessIdentity(
    executablePath: expectedPath, expectedExecutablePath: expectedPath,
    packagedBundleIdentifier: "wrong.bundle", reportedBundleIdentifier: nil
))
precondition(!isExpectedProcessIdentity(
    executablePath: expectedPath, expectedExecutablePath: expectedPath,
    packagedBundleIdentifier: expectedBundleID, reportedBundleIdentifier: "wrong.bundle"
))
let first = AXUIElementCreateApplication(Int32.max - 1)
let repeatedReference = AXUIElementCreateApplication(Int32.max - 1)
let distinct = AXUIElementCreateApplication(Int32.max - 2)
precondition(CFEqual(first, repeatedReference))
precondition(!CFEqual(first, distinct))
precondition(uniqueElement([]) == nil)
precondition(uniqueElement([first]).map { CFEqual($0, first) } == true)
precondition(uniqueElement([first, repeatedReference, first]).map { CFEqual($0, first) } == true)
precondition(uniqueElement([first, repeatedReference, distinct]) == nil)
let password = AXUIElementCreateApplication(Int32.max - 3)
let targets = [first, distinct, password]
func index(of element: AXUIElement) -> Int { targets.firstIndex { CFEqual($0, element) }! }
var calls: [String] = []
let values = ["synthetic-client", "synthetic-username", "synthetic-password"]
precondition(fillDirectFields(targets, values: values, focus: { target in
    calls.append("focus-\(index(of: target))")
    return true
}, setValue: { target, value in
    let position = index(of: target)
    precondition(value == values[position])
    calls.append("set-\(position)")
    return true
}))
precondition(calls == ["focus-0", "set-0", "focus-1", "set-1", "focus-2", "set-2", "focus-0"])
for failedOperation in ["focus-1", "set-1"] {
    calls = []
    precondition(!fillDirectFields(targets, values: values, focus: { target in
        let operation = "focus-\(index(of: target))"
        calls.append(operation)
        return operation != failedOperation
    }, setValue: { target, _ in
        let operation = "set-\(index(of: target))"
        calls.append(operation)
        return operation != failedOperation
    }))
    precondition(calls.last == failedOperation)
    precondition(!calls.contains("focus-2"))
}
print("selection-passed")
'''


if __name__ == "__main__":
    unittest.main()

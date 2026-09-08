import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var result = attribute(element, "AXChildren") as? [AXUIElement] ?? []
    if let extra = attribute(element, "AXExtrasMenuBar"), CFGetTypeID(extra) == AXUIElementGetTypeID() {
        result.append(unsafeBitCast(extra, to: AXUIElement.self))
    }
    return result
}

func elements(_ element: AXUIElement) -> [AXUIElement] {
    var visited: [AXUIElement] = []
    func visit(_ current: AXUIElement, depth: Int) {
        guard depth < 15, !visited.contains(where: { CFEqual($0, current) }) else { return }
        visited.append(current)
        for child in children(current) { visit(child, depth: depth + 1) }
    }
    visit(element, depth: 0)
    return visited
}

func record(_ element: AXUIElement) -> [String: Any] {
    var result: [String: Any] = [:]
    for key in ["AXRole", "AXTitle", "AXDescription", "AXHelp", "AXValue", "AXIdentifier", "AXEnabled"] {
        if let value = attribute(element, key) { result[key] = String(describing: value) }
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    if let value = attribute(element, "AXPosition"), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point)
    }
    if let value = attribute(element, "AXSize"), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size)
    }
    result["frame"] = [[point.x, point.y], [size.width, size.height]]
    return result
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 1, let pid = Int32(arguments[0]), AXIsProcessTrusted()
else { fatalError("Require a VikingBar PID and Accessibility permission.") }
var runningApp = NSRunningApplication(processIdentifier: pid)
let registrationDeadline = ProcessInfo.processInfo.systemUptime + 3
// Launch Services can publish the bundle identity after the process starts.
while runningApp?.bundleIdentifier == nil, ProcessInfo.processInfo.systemUptime < registrationDeadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    runningApp = NSRunningApplication(processIdentifier: pid)
}
guard let app = runningApp, app.bundleIdentifier == "be.bram.vikingbar"
else { fatalError("Require a registered VikingBar application.") }
let tree = elements(AXUIElementCreateApplication(pid))
if arguments.count == 3, arguments[1] == "press" {
    let menuItem = tree.first(where: {
        (attribute($0, "AXRole") as? String) == "AXMenuItem"
            && (attribute($0, "AXTitle") as? String) == arguments[2]
    })
    guard let selected = menuItem ?? tree.first(where: {
        (attribute($0, "AXIdentifier") as? String) == arguments[2]
            || (attribute($0, "AXTitle") as? String) == arguments[2]
            || ((attribute($0, "AXRole") as? String) == "AXPopUpButton"
                && (attribute($0, "AXValue") as? String) == arguments[2])
            || ((attribute($0, "AXRole") as? String) == "AXRadioButton"
                && (attribute($0, "AXDescription") as? String) == arguments[2])
    }) else { fatalError("Requested accessibility element is absent.") }
    let target: AXUIElement
    if (attribute(selected, "AXRole") as? String) == "AXGroup" {
        let disclosures = elements(selected).filter { (attribute($0, "AXRole") as? String) == "AXDisclosureTriangle" }
        guard disclosures.count == 1 else { fatalError("Require one disclosure inside the selected group.") }
        target = disclosures[0]
    } else {
        target = selected
    }
    let isQuit = (attribute(target, "AXIdentifier") as? String) == "vikingbar.quit"
    guard !app.isTerminated else { fatalError("Target application already terminated.") }
    let pressResult = AXUIElementPerformAction(target, kAXPressAction as CFString)
    if isQuit {
        // Quit can disconnect Accessibility before AXPress returns its response.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !app.isTerminated, ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard app.isTerminated else { fatalError("Application did not terminate after Quit.") }
    } else if pressResult != .success {
        fatalError("Accessibility press failed.")
    }
    print("{\"pressed\":\"\(arguments[2])\",\"pid\":\(pid)}")
} else {
    let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
    let result: [String: Any] = ["pid": pid, "activationPolicy": app.activationPolicy.rawValue,
                               "elements": tree.map(record), "windows": windows]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
}

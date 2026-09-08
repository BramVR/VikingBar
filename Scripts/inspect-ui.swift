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

enum ResolutionFailure: Error {
    case timeout, ambiguous, unavailable
}

func uniqueTarget<T>(_ candidates: [T]) throws -> T? {
    guard candidates.count <= 1 else { throw ResolutionFailure.ambiguous }
    return candidates.first
}

func readyTarget<T>(_ target: T, visible: Bool, enabled: Bool) -> T? {
    visible && enabled ? target : nil
}

func resolveAndPerform<T>(
    timeout: TimeInterval,
    now: () -> TimeInterval,
    pause: () -> Void,
    resolve: () throws -> T?,
    perform: (T) throws -> Void
) throws {
    let deadline = now() + timeout
    while true {
        if let target = try resolve() {
            try perform(target)
            return
        }
        guard now() < deadline else { throw ResolutionFailure.timeout }
        pause()
        guard now() < deadline else { throw ResolutionFailure.timeout }
    }
}

func isFinitePositiveRectangle(_ rectangle: CGRect) -> Bool {
    rectangle.origin.x.isFinite && rectangle.origin.y.isFinite
        && rectangle.size.width.isFinite && rectangle.size.height.isFinite
        && rectangle.size.width > 0 && rectangle.size.height > 0
        && rectangle.maxX.isFinite && rectangle.maxY.isFinite
}

func activeDisplayBounds() throws -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        throw ResolutionFailure.unavailable
    }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
        throw ResolutionFailure.unavailable
    }
    let bounds = displays.prefix(Int(count)).map(CGDisplayBounds)
    guard !bounds.isEmpty, bounds.allSatisfy(isFinitePositiveRectangle) else {
        throw ResolutionFailure.unavailable
    }
    return bounds
}

func isVisible(_ element: AXUIElement, displays: [CGRect]) -> Bool {
    guard let position = attribute(element, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
          let dimensions = attribute(element, "AXSize"), CFGetTypeID(dimensions) == AXValueGetTypeID()
    else { return false }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0 else { return false }
    let frame = CGRect(origin: point, size: size)
    return isFinitePositiveRectangle(frame) && displays.contains { $0.contains(frame) }
}

func resolveTarget(
    root: AXUIElement,
    selector: String,
    menuOnly: Bool = false,
    identifierOnly: Bool = false
) throws -> AXUIElement? {
    let displays = try activeDisplayBounds()
    let tree = elements(root)
    let menuItems = tree.filter {
        (attribute($0, "AXRole") as? String) == "AXMenuItem"
            && (attribute($0, "AXTitle") as? String) == selector
    }
    let candidates = !menuOnly && !identifierOnly && !menuItems.isEmpty ? menuItems : tree
    let matches = candidates.filter { element in
        let role = attribute(element, "AXRole") as? String
        if menuOnly {
            return role == "AXMenuItem" && (attribute(element, "AXTitle") as? String) == selector
                && isVisible(element, displays: displays)
        }
        if identifierOnly {
            return role == "AXPopUpButton" && (attribute(element, "AXIdentifier") as? String) == selector
        }
        return (attribute(element, "AXIdentifier") as? String) == selector
            || (attribute(element, "AXTitle") as? String) == selector
            || (role == "AXPopUpButton" && (attribute(element, "AXValue") as? String) == selector)
            || (role == "AXRadioButton" && (attribute(element, "AXDescription") as? String) == selector)
    }
    guard let selected = try uniqueTarget(matches) else { return nil }
    let target: AXUIElement
    if (attribute(selected, "AXRole") as? String) == "AXGroup" {
        let disclosures = elements(selected).filter {
            (attribute($0, "AXRole") as? String) == "AXDisclosureTriangle"
        }
        guard let disclosure = try uniqueTarget(disclosures) else { return nil }
        target = disclosure
    } else {
        target = selected
    }
    return readyTarget(target, visible: isVisible(target, displays: displays),
                       enabled: (attribute(target, "AXEnabled") as? Bool) == true)
}

func press(_ target: AXUIElement, application: NSRunningApplication) throws {
    guard !application.isTerminated else { throw ResolutionFailure.unavailable }
    let isQuit = (attribute(target, "AXIdentifier") as? String) == "vikingbar.quit"
    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    if isQuit {
        // Quit can disconnect Accessibility before AXPress returns its response.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !application.isTerminated, ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard application.isTerminated else { throw ResolutionFailure.unavailable }
    } else if result != .success {
        throw ResolutionFailure.unavailable
    }
}

func writeJSON(_ result: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
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
let root = AXUIElementCreateApplication(pid)
if arguments.count == 3, arguments[1] == "press" {
    try resolveAndPerform(
        timeout: 3,
        now: { ProcessInfo.processInfo.systemUptime },
        pause: { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) },
        resolve: {
            guard !app.isTerminated else { throw ResolutionFailure.unavailable }
            return try resolveTarget(root: root, selector: arguments[2])
        },
        perform: { try press($0, application: app) }
    )
    try writeJSON(["pressed": arguments[2], "pid": pid])
} else if arguments.count == 4, arguments[1] == "choose" {
    try resolveAndPerform(
        timeout: 3,
        now: { ProcessInfo.processInfo.systemUptime },
        pause: { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) },
        resolve: {
            guard !app.isTerminated else { throw ResolutionFailure.unavailable }
            return try resolveTarget(root: root, selector: arguments[2], identifierOnly: true)
        },
        perform: { try press($0, application: app) }
    )
    try resolveAndPerform(
        timeout: 3,
        now: { ProcessInfo.processInfo.systemUptime },
        pause: { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) },
        resolve: {
            guard !app.isTerminated else { throw ResolutionFailure.unavailable }
            return try resolveTarget(root: root, selector: arguments[3], menuOnly: true)
        },
        perform: { try press($0, application: app) }
    )
    try writeJSON(["chosen": arguments[3], "picker": arguments[2], "pid": pid])
} else {
    guard arguments.count == 1 else { fatalError("Use PID, PID press SELECTOR, or PID choose PICKER TITLE.") }
    let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
    try writeJSON(["pid": pid, "activationPolicy": app.activationPolicy.rawValue,
                   "elements": elements(root).map(record), "windows": windows])
}

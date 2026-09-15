import AppKit
import ApplicationServices
import Darwin

let expectedBundleIdentifier = "be.bram.vikingbar"

func canonicalExecutablePath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

func isExpectedProcessIdentity(
    executablePath: String?, expectedExecutablePath: String,
    packagedBundleIdentifier: String?, reportedBundleIdentifier: String?
) -> Bool {
    if let reportedBundleIdentifier {
        return reportedBundleIdentifier == expectedBundleIdentifier
    }
    return executablePath == expectedExecutablePath
        && packagedBundleIdentifier == expectedBundleIdentifier
}

func processExecutablePath(_ pid: Int32) -> String? {
    var path = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return String(cString: path)
}

func packagedBundleIdentifier(_ infoPlistURL: URL) -> String? {
    guard let data = try? Data(contentsOf: infoPlistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dictionary = plist as? [String: Any]
    else { return nil }
    return dictionary["CFBundleIdentifier"] as? String
}

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

func recordTraversal(
    _ element: AXUIElement,
    depth: Int,
    elements: inout [AXUIElement],
    shallowestDepths: inout [(element: AXUIElement, depth: Int)]) -> Bool
{
    guard depth < 15 else { return false }
    if let index = shallowestDepths.firstIndex(where: { CFEqual($0.element, element) }) {
        guard depth < shallowestDepths[index].depth else { return false }
        shallowestDepths[index].depth = depth
        return true
    }
    shallowestDepths.append((element, depth))
    elements.append(element)
    return true
}

func elements(_ element: AXUIElement) -> [AXUIElement] {
    var visited: [AXUIElement] = []
    var shallowestDepths: [(element: AXUIElement, depth: Int)] = []
    func visit(_ current: AXUIElement, depth: Int) {
        guard recordTraversal(
            current,
            depth: depth,
            elements: &visited,
            shallowestDepths: &shallowestDepths) else { return }
        for child in children(current) { visit(child, depth: depth + 1) }
    }
    visit(element, depth: 0)
    return visited
}

func uniqueElement(_ matches: [AXUIElement]) -> AXUIElement? {
    guard let first = matches.first, matches.dropFirst().allSatisfy({ CFEqual(first, $0) }) else { return nil }
    return first
}

func fillDirectFields(
    _ targets: [AXUIElement], values: [String],
    focus: (AXUIElement) -> Bool, setValue: (AXUIElement, String) -> Bool
) -> Bool {
    guard let first = targets.first, targets.count == values.count else { return false }
    for (target, value) in zip(targets, values) {
        guard focus(target), setValue(target, value) else { return false }
    }
    return focus(first)
}

func record(_ element: AXUIElement, redactText: Bool = false) -> [String: Any] {
    var result: [String: Any] = [:]
    let keys = redactText
        ? ["AXRole", "AXSubrole", "AXIdentifier", "AXEnabled"]
        : ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXHelp", "AXValue", "AXIdentifier", "AXEnabled"]
    for key in keys {
        if let value = attribute(element, key) { result[key] = String(describing: value) }
    }
    if redactText, let identifier = attribute(element, "AXIdentifier") as? String,
       ["vikingbar.connect.client-id", "vikingbar.connect.username", "vikingbar.connect.password"].contains(identifier) {
        result["valueEmpty"] = (attribute(element, "AXValue") as? String)?.isEmpty == true
    }
    if redactText, (attribute(element, "AXIdentifier") as? String) == "vikingbar.connect.error" {
        let codes = ["Enter all three fields.": "required-fields",
                     "Fixture mode does not connect to an account.": "fixture-direct",
                     "Fixture mode does not read 1Password.": "fixture-one-password"]
        for key in ["AXValue", "AXTitle", "AXDescription"] {
            if let text = attribute(element, key) as? String, let code = codes[text] {
                result["messageCode"] = code
            }
        }
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

func uniqueNonScrollTarget<T>(_ candidates: [T], role: (T) -> String?) throws -> T? {
    try uniqueTarget(candidates.filter { role($0) != "AXScrollArea" })
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
            guard now() < deadline else { throw ResolutionFailure.timeout }
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
    guard let selected = try uniqueNonScrollTarget(matches, role: { attribute($0, "AXRole") as? String })
    else { return nil }
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
guard let helperURL = Bundle.main.executableURL else { fatalError("Require the inspect-ui executable location.") }
let packagedAppURL = helperURL.deletingLastPathComponent()
    .appendingPathComponent("app/VikingBar.app", isDirectory: true)
let expectedExecutablePath = canonicalExecutablePath(
    packagedAppURL.appendingPathComponent("Contents/MacOS/VikingBarApp").path
)
let packagedInfoPlistURL = packagedAppURL.appendingPathComponent("Contents/Info.plist")
var runningApp = NSRunningApplication(processIdentifier: pid)
let registrationDeadline = ProcessInfo.processInfo.systemUptime + 3
while runningApp == nil, ProcessInfo.processInfo.systemUptime < registrationDeadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    runningApp = NSRunningApplication(processIdentifier: pid)
}
guard let app = runningApp,
      isExpectedProcessIdentity(
          executablePath: processExecutablePath(pid).map { canonicalExecutablePath($0) },
          expectedExecutablePath: expectedExecutablePath,
          packagedBundleIdentifier: packagedBundleIdentifier(packagedInfoPlistURL),
          reportedBundleIdentifier: app.bundleIdentifier
      )
else { fatalError("Require the packaged VikingBar application.") }
let root = AXUIElementCreateApplication(pid)
if arguments.count == 2, arguments[1] == "fill-direct" {
    let tree = elements(root)
    var inputInfo = stat()
    guard fstat(STDIN_FILENO, &inputInfo) == 0, inputInfo.st_mode & S_IFMT == S_IFIFO else { exit(1) }
    do {
        var data = Data()
        while data.count <= 16384 {
            let chunk = try FileHandle.standardInput.read(upToCount: 16385 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= 16384,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(payload.keys) == Set(["client_id", "username", "password"])
        else { exit(1) }
        data.resetBytes(in: 0..<data.count)
        let fields = [("client_id", "client-id"), ("username", "username"), ("password", "password")]
        var targets: [AXUIElement] = []
        for (_, identifier) in fields {
            let matches = tree.filter { (attribute($0, "AXIdentifier") as? String) == "vikingbar.connect." + identifier }
            guard let target = uniqueElement(matches) else { exit(1) }
            targets.append(target)
        }
        guard (attribute(targets[2], "AXSubrole") as? String) == "AXSecureTextField" else { exit(1) }
        let filled = fillDirectFields(targets, values: fields.map { payload[$0.0]! }, focus: { target in
            guard AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            else { return false }
            return (attribute(target, kAXFocusedAttribute as String) as? Bool) == true
        }, setValue: { target, value in
            AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFString) == .success
        })
        guard filled else { exit(1) }
        print("{\"filled\":true}")
    } catch {
        exit(1)
    }
} else if arguments.count == 3, arguments[1] == "press" {
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
    let tree = elements(root)
    let formVisible = tree.contains { (attribute($0, "AXIdentifier") as? String) == "vikingbar.connect.password" }
    let safeWindows = windows.map { window in
        formVisible ? window.filter { $0.key != kCGWindowName as String } : window
    }
    let result: [String: Any] = ["pid": pid, "activationPolicy": app.activationPolicy.rawValue,
                               "elements": tree.map { record($0, redactText: formVisible) }, "windows": safeWindows]
    try writeJSON(result)
}

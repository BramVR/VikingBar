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

func elements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 15 else { return [] }
    return [element] + children(element).flatMap { elements($0, depth: depth + 1) }
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
if arguments.count == 2, arguments[1] == "fill-direct" {
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
            guard matches.count == 1 else { exit(1) }
            targets.append(matches[0])
        }
        guard (attribute(targets[2], "AXSubrole") as? String) == "AXSecureTextField" else { exit(1) }
        for (index, field) in fields.enumerated() {
            guard AXUIElementSetAttributeValue(targets[index], kAXValueAttribute as CFString,
                                              payload[field.0]! as CFString) == .success else { exit(1) }
        }
        print("{\"filled\":true}")
    } catch {
        exit(1)
    }
} else if arguments.count == 3, arguments[1] == "press" {
    let menuItem = tree.first(where: {
        (attribute($0, "AXRole") as? String) == "AXMenuItem"
            && (attribute($0, "AXTitle") as? String) == arguments[2]
    })
    guard let target = menuItem ?? tree.first(where: {
        (attribute($0, "AXIdentifier") as? String) == arguments[2]
            || (attribute($0, "AXTitle") as? String) == arguments[2]
            || ((attribute($0, "AXRole") as? String) == "AXPopUpButton"
                && (attribute($0, "AXValue") as? String) == arguments[2])
            || ((attribute($0, "AXRole") as? String) == "AXRadioButton"
                && (attribute($0, "AXDescription") as? String) == arguments[2])
    }) else { fatalError("Requested accessibility element is absent.") }
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
    let formVisible = tree.contains { (attribute($0, "AXIdentifier") as? String) == "vikingbar.connect.password" }
    let safeWindows = windows.map { window in
        formVisible ? window.filter { $0.key != kCGWindowName as String } : window
    }
    let result: [String: Any] = ["pid": pid, "activationPolicy": app.activationPolicy.rawValue,
                               "elements": tree.map { record($0, redactText: formVisible) }, "windows": safeWindows]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
}

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

func elements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 15 else { return [] }
    return [element] + children(element).flatMap { elements($0, depth: depth + 1) }
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

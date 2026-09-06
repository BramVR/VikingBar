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

func record(_ element: AXUIElement) -> [String: Any] {
    var result: [String: Any] = [:]
    for key in ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier"] {
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
guard arguments.count >= 1, let pid = Int32(arguments[0]), AXIsProcessTrusted(),
      let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "be.bram.vikingbar"
else { fatalError("Require a VikingBar PID and Accessibility permission.") }
let tree = elements(AXUIElementCreateApplication(pid))
if arguments.count == 3, arguments[1] == "press" {
    guard let target = tree.first(where: {
        (attribute($0, "AXIdentifier") as? String) == arguments[2]
            || (attribute($0, "AXTitle") as? String) == arguments[2]
    }) else { fatalError("Requested accessibility element is absent.") }
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
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

import math
from pathlib import Path


class UIFailure(Exception):
    pass


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def frame(element):
    try:
        (x, y), (width, height) = element["frame"]
        values = (x, y, width, height)
        if (all(type(value) in (int, float) and math.isfinite(value) for value in values)
                and width > 0 and height > 0 and math.isfinite(x + width) and math.isfinite(y + height)):
            return values
    except (KeyError, TypeError, ValueError, OverflowError):
        pass
    raise UIFailure("native-frame-invalid")


def contained(element, boundary):
    try:
        x, y, width, height = frame(element)
        bx, by, bw, bh = frame(boundary)
        return x >= bx and y >= by and x + width <= bx + bw and y + height <= by + bh
    except UIFailure:
        return False


def display_frames(screens):
    displays = []
    for screen in screens:
        try:
            bounds = screen["bounds"]
            display = {"frame": [[bounds["x"], bounds["y"]], [bounds["width"], bounds["height"]]]}
            frame(display)
            displays.append(display)
        except (KeyError, TypeError, UIFailure):
            pass
    return displays


def visible_status(tree, screens):
    displays = display_frames(screens)
    return any(element.get("AXIdentifier") == "vikingbar.status"
               and any(contained(element, display) for display in displays)
               for element in tree.get("elements", []))


def popover_window(tree, screens):
    displays = display_frames(screens)
    for element in tree.get("elements", []):
        if element.get("AXRole") != "AXPopover":
            continue
        try:
            ax_frame = frame(element)
        except UIFailure:
            continue
        for window in tree.get("windows", []):
            try:
                bounds = window["kCGWindowBounds"]
                cg_element = {"frame": [[bounds["X"], bounds["Y"]], [bounds["Width"], bounds["Height"]]]}
                cg_frame = frame(cg_element)
            except (KeyError, TypeError, UIFailure):
                continue
            if (all(abs(ax - cg) < 1 for ax, cg in zip(ax_frame, cg_frame))
                    and any(contained(element, display) and contained(cg_element, display) for display in displays)):
                return element, window
    raise UIFailure("native-popover-not-visible")


def capture_popover_window(tree, screens, pid):
    displays = display_frames(screens)
    matches = []
    for element in tree.get("elements", []):
        if element.get("AXRole") != "AXPopover":
            continue
        try:
            ax_frame = frame(element)
        except UIFailure:
            continue
        for window in tree.get("windows", []):
            try:
                bounds = window["kCGWindowBounds"]
                cg_element = {"frame": [[bounds["X"], bounds["Y"]], [bounds["Width"], bounds["Height"]]]}
                cg_frame = frame(cg_element)
                alpha = window["kCGWindowAlpha"]
            except (KeyError, TypeError, UIFailure):
                continue
            if (type(alpha) not in (int, float) or not math.isfinite(alpha) or alpha < 0.99
                    or window.get("kCGWindowOwnerPID") != pid
                    or window.get("kCGWindowIsOnscreen") is not True
                    or not all(abs(ax - cg) < 1 for ax, cg in zip(ax_frame, cg_frame))):
                continue
            if any(contained(element, display) and contained(cg_element, display) for display in displays):
                matches.append((element, window))
    if len(matches) != 1:
        raise UIFailure(f"native-capture-popover-match-count-{len(matches)}")
    return matches[0]


def capture_popover_identity(pid, element, window):
    bounds = window["kCGWindowBounds"]
    return (pid, window["kCGWindowNumber"], frame(element),
            (bounds["X"], bounds["Y"], bounds["Width"], bounds["Height"]))


class CapturePopoverStability:
    def __init__(self):
        self.identity = None
        self.count = 0

    def reset(self):
        self.identity = None
        self.count = 0

    def observe(self, tree, screens, pid, qualifies=lambda _element, _window: True):
        try:
            element, window = capture_popover_window(tree, screens, pid)
            identity = capture_popover_identity(pid, element, window)
            if not qualifies(element, window):
                self.reset()
                return None
        except (KeyError, TypeError, UIFailure):
            self.reset()
            return None
        if identity == self.identity:
            self.count += 1
        else:
            self.identity = identity
            self.count = 1
        return (element, window) if self.count >= 2 else None


def capture_exact_window(peekaboo, pid, window_id, output, invoke):
    output = Path(output)
    arguments = [str(peekaboo), "see", "--pid", str(pid), "--window-id", str(window_id),
                 "--capture-engine", "classic", "--no-elements", "--no-remote",
                 "--path", str(output), "--json"]
    receipt = invoke(arguments)
    if not isinstance(receipt, dict) or receipt.get("success") is not True:
        raise UIFailure("native-capture-command-failed")
    target = receipt.get("target_receipt")
    if (not isinstance(target, dict) or target.get("pid") != pid
            or target.get("window_id") != window_id):
        raise UIFailure("native-capture-target-mismatch")
    data = receipt.get("data")
    files = data.get("files") if isinstance(data, dict) else None
    if (not isinstance(files, list) or len(files) != 1 or not isinstance(files[0], dict)
            or files[0].get("path") != str(output) or files[0].get("window_id") != window_id
            or files[0].get("item_label") != f"window-{window_id}"
            or files[0].get("mime_type") != "image/png"):
        raise UIFailure("native-capture-output-mismatch")
    try:
        image = output.read_bytes()
    except OSError as error:
        raise UIFailure("native-capture-image-missing") from error
    if len(image) <= len(PNG_SIGNATURE) or not image.startswith(PNG_SIGNATURE):
        raise UIFailure("native-capture-image-invalid")
    return receipt


def visible_value(tree, boundary, identifier, expected):
    return any(item.get("AXIdentifier") == identifier and contained(item, boundary)
               and expected in [item.get(key) for key in ("AXTitle", "AXValue", "AXDescription")]
               for item in tree.get("elements", []))


def bundle_details_visible(tree, screens, title, description, applicability):
    try:
        boundary, _ = popover_window(tree, screens)
    except UIFailure:
        return False
    return all(visible_value(tree, boundary, identifier, text) for identifier, text in (
        ("vikingbar.bundlePicker", title), ("vikingbar.bundleDescription", description),
        ("vikingbar.bundleApplicability", applicability)))


def bundle_details_collapsed(tree, screens):
    try:
        boundary, _ = popover_window(tree, screens)
    except UIFailure:
        return False
    elements = tree.get("elements", [])
    return (any(item.get("AXIdentifier") == "vikingbar.bundleDetails" and contained(item, boundary)
                for item in elements)
            and not any(item.get("AXIdentifier") in ("vikingbar.bundleDescription", "vikingbar.bundleApplicability")
                        for item in elements))

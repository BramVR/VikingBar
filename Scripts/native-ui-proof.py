import math


class UIFailure(Exception):
    pass


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

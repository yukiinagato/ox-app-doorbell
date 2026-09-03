"""SVG path data: parse, and flatten to polylines.

Written for tools/gen_icons.py. Android VectorDrawable and WPF/XAML both take SVG path syntax
straight through, so they keep the exact upstream geometry; the raster and PDF outputs need the
curves and arcs turned into line segments first, which is what this module is for.

Only the subset the Tabler outline set actually uses is supported -- M/m, L/l, H/h, V/v, C/c,
S/s, Q/q, T/t, A/a, Z/z -- and an unsupported command raises rather than silently dropping part
of a glyph.
"""

import math
import re

_TOKEN = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")


class PathError(ValueError):
    pass


def tokens(data):
    """Command letters and numbers, in order. Anything else in the string is ignored."""
    return _TOKEN.findall(data)


def _tokens(data):
    return tokens(data)


def _flatten_cubic(p0, p1, p2, p3, steps):
    out = []
    for i in range(1, steps + 1):
        t = i / float(steps)
        u = 1.0 - t
        x = (u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0])
        y = (u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1])
        out.append((x, y))
    return out


def _arc_to_cubics(start, rx, ry, rotation, large_arc, sweep, end):
    """Endpoint-parameterised arc to a list of cubic segments (SVG 1.1 appendix F.6)."""
    if rx == 0 or ry == 0 or (abs(start[0] - end[0]) < 1e-12 and abs(start[1] - end[1]) < 1e-12):
        return []
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(rotation)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    dx2 = (start[0] - end[0]) / 2.0
    dy2 = (start[1] - end[1]) / 2.0
    x1 = cos_phi * dx2 + sin_phi * dy2
    y1 = -sin_phi * dx2 + cos_phi * dy2
    # Scale the radii up when they are too small to span the chord.
    lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lam > 1:
        scale = math.sqrt(lam)
        rx *= scale
        ry *= scale
    num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    factor = 0.0 if num <= 0 or den == 0 else math.sqrt(num / den)
    if large_arc == sweep:
        factor = -factor
    cx1 = factor * rx * y1 / ry
    cy1 = -factor * ry * x1 / rx
    cx = cos_phi * cx1 - sin_phi * cy1 + (start[0] + end[0]) / 2.0
    cy = sin_phi * cx1 + cos_phi * cy1 + (start[1] + end[1]) / 2.0

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        length = math.hypot(ux, uy) * math.hypot(vx, vy)
        if length == 0:
            return 0.0
        value = max(-1.0, min(1.0, dot / length))
        result = math.acos(value)
        return -result if ux * vy - uy * vx < 0 else result

    theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    segments = max(1, int(math.ceil(abs(delta) / (math.pi / 2))))
    step = delta / segments
    alpha = math.sin(step) * (math.sqrt(4 + 3 * math.tan(step / 2) ** 2) - 1) / 3.0
    cubics = []
    theta = theta1
    current = start
    for _ in range(segments):
        cos_t, sin_t = math.cos(theta), math.sin(theta)
        theta_next = theta + step
        cos_n, sin_n = math.cos(theta_next), math.sin(theta_next)

        def point(ct, st):
            px = cos_phi * rx * ct - sin_phi * ry * st + cx
            py = sin_phi * rx * ct + cos_phi * ry * st + cy
            return (px, py)

        def derivative(ct, st):
            dx = -cos_phi * rx * st - sin_phi * ry * ct
            dy = -sin_phi * rx * st + cos_phi * ry * ct
            return (dx, dy)

        end_point = point(cos_n, sin_n)
        d1 = derivative(cos_t, sin_t)
        d2 = derivative(cos_n, sin_n)
        c1 = (current[0] + alpha * d1[0], current[1] + alpha * d1[1])
        c2 = (end_point[0] - alpha * d2[0], end_point[1] - alpha * d2[1])
        cubics.append((c1, c2, end_point))
        current = end_point
        theta = theta_next
    return cubics


def flatten(data, curve_steps=16):
    """Return [(closed, [(x, y), ...]), ...] for one path data string."""
    tokens = _tokens(data)
    index = 0
    command = None
    current = (0.0, 0.0)
    start = (0.0, 0.0)
    last_cubic_control = None
    last_quad_control = None
    subpaths = []
    points = []
    closed = False

    def flush():
        if len(points) > 1:
            subpaths.append((closed, list(points)))

    def number():
        nonlocal index
        if index >= len(tokens):
            raise PathError("path data ended mid-command")
        token = tokens[index]
        index += 1
        try:
            return float(token)
        except ValueError:
            raise PathError("expected a number, found " + token)

    while index < len(tokens):
        token = tokens[index]
        if token.isalpha():
            command = token
            index += 1
        elif command in (None, "Z", "z"):
            raise PathError("path data starts with a number")
        elif command == "M":
            command = "L"
        elif command == "m":
            command = "l"
        relative = command.islower()
        upper = command.upper()

        if upper == "Z":
            if points:
                closed = True
                flush()
            points = []
            closed = False
            current = start
            continue
        if upper == "M":
            x, y = number(), number()
            if relative:
                x, y = current[0] + x, current[1] + y
            flush()
            points = [(x, y)]
            closed = False
            current = start = (x, y)
            last_cubic_control = last_quad_control = None
            continue
        if upper == "L":
            x, y = number(), number()
            if relative:
                x, y = current[0] + x, current[1] + y
        elif upper == "H":
            x = number()
            if relative:
                x += current[0]
            y = current[1]
        elif upper == "V":
            y = number()
            if relative:
                y += current[1]
            x = current[0]
        elif upper in ("C", "S"):
            if upper == "C":
                c1 = (number(), number())
                c2 = (number(), number())
            else:
                reflected = last_cubic_control or current
                c1 = (2 * current[0] - reflected[0], 2 * current[1] - reflected[1])
                if relative:
                    c1 = (c1[0] - current[0], c1[1] - current[1])
                c2 = (number(), number())
            end = (number(), number())
            if relative:
                c1 = (current[0] + c1[0], current[1] + c1[1])
                c2 = (current[0] + c2[0], current[1] + c2[1])
                end = (current[0] + end[0], current[1] + end[1])
            points.extend(_flatten_cubic(current, c1, c2, end, curve_steps))
            last_cubic_control = c2
            last_quad_control = None
            current = end
            continue
        elif upper in ("Q", "T"):
            if upper == "Q":
                q = (number(), number())
                if relative:
                    q = (current[0] + q[0], current[1] + q[1])
            else:
                reflected = last_quad_control or current
                q = (2 * current[0] - reflected[0], 2 * current[1] - reflected[1])
            end = (number(), number())
            if relative:
                end = (current[0] + end[0], current[1] + end[1])
            c1 = (current[0] + 2.0 / 3.0 * (q[0] - current[0]),
                  current[1] + 2.0 / 3.0 * (q[1] - current[1]))
            c2 = (end[0] + 2.0 / 3.0 * (q[0] - end[0]), end[1] + 2.0 / 3.0 * (q[1] - end[1]))
            points.extend(_flatten_cubic(current, c1, c2, end, curve_steps))
            last_quad_control = q
            last_cubic_control = None
            current = end
            continue
        elif upper == "A":
            rx, ry, rotation = number(), number(), number()
            large_arc, sweep = number() != 0, number() != 0
            end = (number(), number())
            if relative:
                end = (current[0] + end[0], current[1] + end[1])
            for c1, c2, stop in _arc_to_cubics(current, rx, ry, rotation, large_arc, sweep, end):
                points.extend(_flatten_cubic(current, c1, c2, stop, curve_steps))
                current = stop
            current = end
            if not points or points[-1] != end:
                points.append(end)
            last_cubic_control = last_quad_control = None
            continue
        else:
            raise PathError("unsupported path command " + str(command))
        points.append((x, y))
        current = (x, y)
        last_cubic_control = last_quad_control = None

    flush()
    return subpaths

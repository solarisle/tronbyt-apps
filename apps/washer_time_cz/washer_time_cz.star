"""
Applet: Washer Time CZ
Summary: Best times for appliances
Description: Rotates the top 3 upcoming windows on the Czech OTE 15-minute spot market: the cheapest times to run a washing machine, or the most expensive times to keep electric heating off.
Author: Tronbyt
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "canvas", "render")
load("schema.star", "schema")
load("time.star", "time")

PRICES_URL = "https://spotovaelektrina.cz/api/v1/price/get-prices-json-qh"
CACHE_TTL = 900
TZ = "Europe/Prague"
VAT = 1.21

BG_COLOR = "#000000"
LABEL_COLOR = "#8A8A8A"
BODY_COLOR = "#B0BEC5"
NOW_COLOR = "#00E676"
LATER_COLOR = "#40C4FF"
SAVE_COLOR = "#00E676"
AVOID_COLOR = "#FF3D3D"
OK_COLOR = "#00E676"
LAUNDRY_COLOR = "#FFFFFF"
HEAT_COLOR = "#FF9100"
DOT_DIM_COLOR = "#3A3A3A"
FRAME_DELAY = 100
PAGE_FRAMES = 30  # each of the top windows is shown for 3 s
TOP_WINDOWS = 3

# laundry pixels tumbling inside the door, clockwise (row, col)
DRUM_PATH = [(5, 4), (5, 5), (5, 6), (6, 7), (7, 7), (8, 6), (8, 5), (8, 4), (7, 3), (6, 3)]

# 11x12 washing machine, "o" = door (accent colour)
WASHER = [
    "###########",
    "#.#.#.....#",
    "###########",
    "#.........#",
    "#...ooo...#",
    "#..o...o..#",
    "#.o.....o.#",
    "#.o.....o.#",
    "#..o...o..#",
    "#...ooo...#",
    "#.........#",
    "###########",
]

# 11x12 radiator: "#" = fins (accent colour), "=" = pipe/feet; rows 0-3 hold rising heat
HEATER = [
    "...........",
    "...........",
    "...........",
    "...........",
    "##.##.##.##",
    "##.##.##.##",
    "##.##.##.##",
    "##.##.##.##",
    "##.##.##.##",
    "##.##.##.##",
    "===========",
    ".=.......=.",
]
HEAT_COLUMNS = [0, 4, 6, 10]

def _format_price(value):
    cents = int(math.round(value * 100))
    sign = "-" if cents < 0 else ""
    cents = -cents if cents < 0 else cents
    frac = str(cents % 100)
    if len(frac) < 2:
        frac = "0" + frac
    return "%s%d,%s" % (sign, cents // 100, frac)

def _two(n):
    return str(n) if n >= 10 else "0" + str(n)

def _slot_time(slot):
    return "%s:%s" % (_two(int(slot["hour"])), _two(int(slot["minute"])))

def _end_time(slot):
    # end of a 15-minute slot
    m = int(slot["hour"]) * 60 + int(slot["minute"]) + 15
    return "%s:%s" % (_two((m // 60) % 24), _two(m % 60))

def _fetch_prices():
    res = http.get(PRICES_URL, ttl_seconds = CACHE_TTL)
    if res.status_code != 200:
        return None
    return res.json()

def _find_slot(slots, hour, minute):
    for i, s in enumerate(slots):
        if int(s["hour"]) == hour and int(s["minute"]) == minute:
            return i
    return -1

def _hour_allowed(hour, start_from, start_until):
    if start_from == start_until:
        return True
    if start_from < start_until:
        return hour >= start_from and hour < start_until

    # window wraps midnight, e.g. 22 → 6
    return hour >= start_from or hour < start_until

def _rank_windows(slots, first, length, start_from, start_until, avoid):
    # slots: list of (price, slot, is_tomorrow). Returns up to TOP_WINDOWS non-overlapping
    # (index, average) windows, cheapest first — or most expensive first when avoid is set.
    candidates = []
    for i in range(first, len(slots) - length + 1):
        if not _hour_allowed(int(slots[i][1]["hour"]), start_from, start_until):
            continue
        total = 0.0
        for j in range(i, i + length):
            total += slots[j][0]
        candidates.append((i, total / length))
    candidates = sorted(candidates, key = lambda c: -c[1] if avoid else c[1])

    picked = []
    for i, avg in candidates:
        overlaps = False
        for k, _ in picked:
            if abs(i - k) < length:
                overlaps = True
                break
        if not overlaps:
            picked.append((i, avg))
            if len(picked) == TOP_WINDOWS:
                break
    return picked

def _washer_icon(scale, accent, step):
    px = 1 * scale
    n = len(DRUM_PATH)
    laundry = [DRUM_PATH[step % n], DRUM_PATH[(step + n // 2) % n]] if step >= 0 else []
    rows = []
    for r, row in enumerate(WASHER):
        cells = []
        for c, ch in enumerate(row.elems()):
            if (r, c) in laundry:
                color = LAUNDRY_COLOR
            else:
                color = BODY_COLOR if ch == "#" else (accent if ch == "o" else BG_COLOR)
            cells.append(render.Box(width = px, height = px, color = color))
        rows.append(render.Row(children = cells))
    return render.Column(children = rows)

def _heater_icon(scale, accent, step):
    px = 1 * scale
    waves = []
    if step >= 0:
        # heat rising from every fin, each column one row out of phase
        for k, c in enumerate(HEAT_COLUMNS):
            waves.append((3 - (step + k) % 4, c))
    rows = []
    for r, row in enumerate(HEATER):
        cells = []
        for c, ch in enumerate(row.elems()):
            if (r, c) in waves:
                color = HEAT_COLOR
            else:
                color = accent if ch == "#" else (BODY_COLOR if ch == "=" else BG_COLOR)
            cells.append(render.Box(width = px, height = px, color = color))
        rows.append(render.Row(children = cells))
    return render.Column(children = rows)

def _animated_icon(heating, scale, accent, frames, moving):
    # moving = False draws a still icon (no laundry / no heat) for the "not recommended" state
    icon = _heater_icon if heating else _washer_icon
    return render.Animation(children = [icon(scale, accent, i if moving else -1) for i in range(frames)])

def _rank_dots(scale, count, current, accent):
    dots = []
    for k in range(count):
        if dots:
            dots.append(render.Box(width = 1 * scale, height = 2 * scale))
        dots.append(render.Box(width = 3 * scale, height = 2 * scale, color = accent if k == current else DOT_DIM_COLOR))
    return render.Row(children = dots)

def _page(scale, width, height, fonts, heating, accent, moving, header, big, blink, footer, side):
    small_font, big_font = fonts
    info = [
        render.Row(
            expanded = True,
            main_align = "space_between",
            children = [render.Text(t, font = small_font, color = LABEL_COLOR) for t in header],
        ),
        render.Animation(
            children = [
                render.Text(big, font = big_font, color = accent if (not blink or i % 10 < 7) else BG_COLOR)
                for i in range(PAGE_FRAMES)
            ],
        ),
        render.Row(
            expanded = True,
            main_align = "space_between",
            children = [render.Text(t, font = small_font, color = c) for t, c in footer],
        ),
    ]
    return render.Box(
        width = width,
        height = height,
        color = BG_COLOR,
        child = render.Padding(
            pad = (1 * scale, 1 * scale, 1 * scale, 1 * scale),
            child = render.Row(
                expanded = True,
                children = [
                    render.Column(
                        cross_align = "center",
                        children = [_animated_icon(heating, scale, accent, PAGE_FRAMES, moving), render.Box(width = 1, height = 2 * scale)] + side,
                    ),
                    render.Box(width = 2 * scale, height = 1),
                    render.Column(
                        expanded = True,
                        main_align = "space_between",
                        children = info,
                    ),
                ],
            ),
        ),
    )

def _render_message(msg):
    return render.Root(
        child = render.Box(
            color = BG_COLOR,
            child = render.WrappedText(msg, font = "tom-thumb", color = LABEL_COLOR, align = "center"),
        ),
    )

def main(config):
    scale = 2 if canvas.is2x() else 1
    width, height = canvas.size()
    small_font = "terminus-12" if scale == 2 else "tom-thumb"
    big_font = "terminus-24" if scale == 2 else "6x13"
    fonts = (small_font, big_font)

    heating = config.str("appliance", "washer") == "heating"
    hours = int(config.str("duration", "2"))
    length = hours * 4
    start_from = int(config.str("start_from", "7"))
    start_until = int(config.str("start_until", "22"))
    with_vat = config.bool("with_vat", False)
    factor = VAT if with_vat else 1.0

    data = _fetch_prices()
    if data == None or not data.get("hoursToday"):
        return _render_message("No price data")

    now = time.now().in_location(TZ)
    today = data["hoursToday"]
    first = _find_slot(today, now.hour, (now.minute // 15) * 15)
    if first < 0:
        return _render_message("No current slot")

    tomorrow = data.get("hoursTomorrow") or []
    slots = [(s["priceCZK"] / 1000.0 * factor, s, False) for s in today]
    slots += [(s["priceCZK"] / 1000.0 * factor, s, True) for s in tomorrow]

    windows = _rank_windows(slots, first, length, start_from, start_until, heating)
    label = "OFF" if heating else "%dh" % hours

    if not windows:
        # nothing left in the allowed hours (passed, or tomorrow not published yet)
        reason = "tmrw 13:00" if not tomorrow else "no slot"
        if heating:
            page = _page(scale, width, height, fonts, True, OK_COLOR, True, [label, ""], "OK", False, [("no peak", LABEL_COLOR), ("", LABEL_COLOR)], [])
        else:
            page = _page(scale, width, height, fonts, False, AVOID_COLOR, False, [label, ""], "NO GO", False, [(reason, LABEL_COLOR), ("", LABEL_COLOR)], [])
        return render.Root(delay = FRAME_DELAY, child = page)

    upcoming_avg = 0.0
    for j in range(first, len(slots)):
        upcoming_avg += slots[j][0]
    upcoming_avg = upcoming_avg / (len(slots) - first)

    now_avg = 0.0
    for j in range(first, first + length):
        now_avg += slots[j][0]
    now_avg = now_avg / length

    pages = []
    for rank, (idx, avg) in enumerate(windows):
        is_now = idx == first
        start_slot = slots[idx][1]
        end_slot = slots[idx + length - 1][1]

        if heating:
            accent = AVOID_COLOR
            diff = avg - upcoming_avg
            delta = ("+" + _format_price(diff), AVOID_COLOR) if diff > 0.005 else ("", AVOID_COLOR)
        else:
            accent = NOW_COLOR if is_now else LATER_COLOR
            diff = now_avg - avg
            delta = ("-" + _format_price(diff), SAVE_COLOR) if diff > 0.005 else ("", SAVE_COLOR)

        if is_now:
            big = "OFF!" if heating else "START!"
        else:
            big = _slot_time(start_slot)

        side = [_rank_dots(scale, len(windows), rank, accent)]
        if slots[idx][2]:
            side.append(render.Box(width = 1, height = 1 * scale))
            side.append(render.Text("+1", font = small_font, color = LABEL_COLOR))

        pages.append(_page(
            scale,
            width,
            height,
            fonts,
            heating,
            accent,
            True,
            [label, "to " + _end_time(end_slot)],
            big,
            is_now,
            [(_format_price(avg), BODY_COLOR), delta],
            side,
        ))

    return render.Root(
        delay = FRAME_DELAY,
        show_full_animation = True,
        child = render.Sequence(children = pages),
    )

def _hour_options():
    return [schema.Option(display = "%s:00" % _two(h), value = str(h)) for h in range(24)]

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "appliance",
                name = "Appliance",
                desc = "Washer shows the cheapest times to run; heating shows the most expensive times to switch off.",
                icon = "plug",
                default = "washer",
                options = [
                    schema.Option(display = "Washing machine / dishwasher", value = "washer"),
                    schema.Option(display = "Electric heating (times to avoid)", value = "heating"),
                ],
            ),
            schema.Dropdown(
                id = "duration",
                name = "Window length",
                desc = "How long the appliance runs (washer) or stays off (heating).",
                icon = "clock",
                default = "2",
                options = [schema.Option(display = "%d h" % h, value = str(h)) for h in [1, 2, 3, 4]],
            ),
            schema.Dropdown(
                id = "start_from",
                name = "Allowed start from",
                desc = "Earliest start hour. Same value as 'until' means any time.",
                icon = "hourglassStart",
                default = "7",
                options = _hour_options(),
            ),
            schema.Dropdown(
                id = "start_until",
                name = "Allowed start until",
                desc = "Latest start hour (exclusive). Can wrap past midnight, e.g. 22 → 6.",
                icon = "hourglassEnd",
                default = "22",
                options = _hour_options(),
            ),
            schema.Toggle(
                id = "with_vat",
                name = "Include VAT (21 %)",
                desc = "Multiply prices by 1.21.",
                icon = "percent",
                default = False,
            ),
        ],
    )

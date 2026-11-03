"""
Applet: Washer Time CZ
Summary: Cheapest time to run appliances
Description: Finds the cheapest upcoming window on the Czech OTE 15-minute spot market for running a washing machine or dishwasher, with average price and saving versus starting now.
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
LAUNDRY_COLOR = "#FFFFFF"
FRAME_DELAY = 100

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

def _best_window(slots, first, length, start_from, start_until):
    # slots: list of (price, slot, is_tomorrow); returns (index, average) of cheapest window
    best = -1
    best_avg = 0.0
    for i in range(first, len(slots) - length + 1):
        if not _hour_allowed(int(slots[i][1]["hour"]), start_from, start_until):
            continue
        total = 0.0
        for j in range(i, i + length):
            total += slots[j][0]
        avg = total / length
        if best < 0 or avg < best_avg:
            best = i
            best_avg = avg
    return best, best_avg

def _icon(scale, accent, step):
    px = 1 * scale
    n = len(DRUM_PATH)
    laundry = [DRUM_PATH[step % n], DRUM_PATH[(step + n // 2) % n]]
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

def _spinning_icon(scale, accent):
    return render.Animation(children = [_icon(scale, accent, i) for i in range(len(DRUM_PATH))])

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

    slots = [(s["priceCZK"] / 1000.0 * factor, s, False) for s in today]
    slots += [(s["priceCZK"] / 1000.0 * factor, s, True) for s in (data.get("hoursTomorrow") or [])]

    best, best_avg = _best_window(slots, first, length, start_from, start_until)
    if best < 0:
        if not data.get("hoursTomorrow"):
            return _render_message("Tomorrow's prices at ~13:00")
        return _render_message("No window in allowed hours")

    now_avg = 0.0
    for j in range(first, first + length):
        now_avg += slots[j][0]
    now_avg = now_avg / length
    saving = now_avg - best_avg

    is_now = best == first
    accent = NOW_COLOR if is_now else LATER_COLOR
    start_slot = slots[best][1]
    end_slot = slots[best + length - 1][1]

    title = "%dh" % hours
    if is_now:
        big = "START!"
    else:
        big = _slot_time(start_slot)
        if slots[best][2]:
            title += " +1"

    info = [
        render.Row(
            expanded = True,
            main_align = "space_between",
            children = [
                render.Text(title, font = small_font, color = LABEL_COLOR),
                render.Text("to " + _end_time(end_slot), font = small_font, color = LABEL_COLOR),
            ],
        ),
        # "START!" blinks when now is the best time
        render.Animation(
            children = [
                render.Text(big, font = big_font, color = accent if (not is_now or i < 7) else BG_COLOR)
                for i in range(len(DRUM_PATH))
            ],
        ),
        render.Row(
            expanded = True,
            main_align = "space_between",
            children = [
                render.Text(_format_price(best_avg), font = small_font, color = BODY_COLOR),
                render.Text("-" + _format_price(saving) if saving > 0.005 else "", font = small_font, color = SAVE_COLOR),
            ],
        ),
    ]

    return render.Root(
        delay = FRAME_DELAY,
        child = render.Box(
            width = width,
            height = height,
            color = BG_COLOR,
            child = render.Padding(
                pad = (1 * scale, 1 * scale, 1 * scale, 1 * scale),
                child = render.Row(
                    expanded = True,
                    cross_align = "center",
                    children = [
                        _spinning_icon(scale, accent),
                        render.Box(width = 2 * scale, height = 1),
                        render.Column(
                            expanded = True,
                            main_align = "space_between",
                            children = info,
                        ),
                    ],
                ),
            ),
        ),
    )

def _hour_options():
    return [schema.Option(display = "%s:00" % _two(h), value = str(h)) for h in range(24)]

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "duration",
                name = "Program length",
                desc = "How long the appliance runs.",
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

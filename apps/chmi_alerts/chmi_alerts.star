"""
Applet: CHMI Alerts
Summary: Czech weather warning light
Description: Active ČHMÚ weather warnings (CAP) for your ORP district, with a yellow/orange/red warning light and scrolling event names.
Author: Tronbyt
"""

load("http.star", "http")
load("math.star", "math")
load("re.star", "re")
load("render.star", "canvas", "render")
load("schema.star", "schema")
load("time.star", "time")
load("xpath.star", "xpath")

CAP_DIR = "https://opendata.chmi.cz/meteorology/weather/alerts/cap/"
LISTING_TTL = 300
CAP_TTL = 3600
TZ = "Europe/Prague"

BG_COLOR = "#000000"
LABEL_COLOR = "#8A8A8A"
TEXT_COLOR = "#FFFFFF"

# awareness level → (name, light colour, background tint)
LEVELS = {
    1: ("CLEAR", "#00E676", "#001A0B"),
    2: ("YELLOW", "#FFD600", "#262000"),
    3: ("ORANGE", "#FF9100", "#2A1400"),
    4: ("RED", "#FF1744", "#2E0008"),
}

SEVERITY_LEVEL = {"Moderate": 2, "Severe": 3, "Extreme": 4}

TRIANGLE = [
    "...#...",
    "..#.#..",
    "..#!#..",
    ".#.!.#.",
    ".#...#.",
    "#..!..#",
    "#######",
]

def _hex2(n):
    s = "%X" % n
    return s if len(s) >= 2 else "0" + s

def _mix(c1, c2, t):
    # linear blend of two "#RRGGBB" colours, t = 0 → c1, t = 1 → c2
    out = "#"
    for k in (1, 3, 5):
        a = int(c1[k:k + 2], 16)
        b = int(c2[k:k + 2], 16)
        out += _hex2(int(a + (b - a) * t))
    return out

def _two(n):
    return str(n) if n >= 10 else "0" + str(n)

def _latest_cap_url():
    # file names only carry day+time, so pick the newest by the listing's modification date
    res = http.get(CAP_DIR, ttl_seconds = LISTING_TTL)
    if res.status_code != 200:
        return None
    best_name = None
    best_time = None
    for entry in re.findall(r"alert_cap_50_\d{6}\.xml</a>\s+\d{2}-\w{3}-\d{4} \d{2}:\d{2}", res.body()):
        name = entry[:23]
        stamp = time.parse_time(entry[-17:], "02-Jan-2006 15:04")
        if best_time == None or stamp > best_time:
            best_name = name
            best_time = stamp
    return CAP_DIR + best_name if best_name else None

def _level_of(awareness, severity):
    # awareness_level looks like "3; orange; Severe"
    if awareness and awareness[0].isdigit():
        return int(awareness[0])
    return SEVERITY_LEVEL.get(severity, 1)

def _fetch_alerts(orp, language):
    url = _latest_cap_url()
    if url == None:
        return None
    res = http.get(url, ttl_seconds = CAP_TTL)
    if res.status_code != 200:
        return None

    doc = xpath.loads(res.body())
    sel = "//info[language='%s'][severity!='Minor'][area/geocode/value='%s']" % (language, orp)
    now = time.now()
    alerts = []
    seen = {}
    for i in range(1, len(doc.query_all(sel + "/event")) + 1):
        node = "(%s)[%d]" % (sel, i)
        event = doc.query(node + "/event")
        expires = doc.query(node + "/expires")
        onset = doc.query(node + "/onset")
        if expires and time.parse_time(expires) < now:
            continue
        level = _level_of(doc.query(node + "/parameter[valueName='awareness_level']/value"), doc.query(node + "/severity"))
        key = event + "|" + str(level)
        if key in seen:
            continue
        seen[key] = True
        alerts.append({
            "event": event,
            "level": level,
            "onset": time.parse_time(onset) if onset else None,
            "expires": time.parse_time(expires) if expires else None,
        })
    return sorted(alerts, key = lambda a: -a["level"])

def _triangle(scale, color, mark):
    px = 1 * scale
    rows = []
    for row in TRIANGLE:
        cells = []
        for c in row.elems():
            fill = color if c == "#" else (mark if c == "!" else None)
            cells.append(render.Box(width = px, height = px, color = fill) if fill else render.Box(width = px, height = px))
        rows.append(render.Row(children = cells))
    return render.Column(children = rows)

def _animated_triangle(scale, level, light, tint, has_alerts):
    # frame counts are multiplied by scale because the 2x root delay is halved
    frames = []
    if has_alerts:
        # square-wave blink: red 0.4 s period, yellow/orange 1 s
        half = (4 if level >= 4 else 10) * scale
        for i in range(2 * half):
            on = i < half
            frames.append(_triangle(scale, light if on else _mix(light, tint, 0.8), TEXT_COLOR if on else tint))
    else:
        # calm 2 s breathing when there is no warning
        n = 40 * scale
        for i in range(n):
            t = (1 - math.cos(2 * math.pi * i / n)) / 2
            frames.append(_triangle(scale, _mix(light, tint, 0.75 * t), tint))
    return render.Animation(children = frames)

def _hhmm(t):
    t = t.in_location(TZ)
    return "%s:%s" % (_two(t.hour), _two(t.minute))

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
    small_font = "terminus-12" if scale == 2 else "tb-8"
    text_font = "10x20" if scale == 2 else "6x13"
    tiny_font = "terminus-12" if scale == 2 else "tom-thumb"

    orp = config.str("orp", "6107").strip()
    language = config.str("language", "cs")
    hide_when_clear = config.bool("hide_when_clear", False)

    alerts = _fetch_alerts(orp, language)
    if alerts == None:
        return _render_message("No ČHMÚ data")
    if not alerts and hide_when_clear:
        return []

    top_level = alerts[0]["level"] if alerts else 1
    name, light, tint = LEVELS.get(top_level, LEVELS[4])

    if alerts:
        now = time.now()
        top = alerts[0]
        if top["onset"] and top["onset"] > now:
            when = "from " + _hhmm(top["onset"])
        elif top["expires"]:
            when = "to " + _hhmm(top["expires"])
        else:
            when = ""
        message = "  ·  ".join([a["event"] for a in alerts])
        chips = [render.Box(width = 4 * scale, height = 2 * scale, color = LEVELS.get(a["level"], LEVELS[4])[1]) for a in alerts[:5]]
    else:
        when = ""
        message = "Bez výstrah" if language == "cs" else "No warnings"
        chips = []

    spaced_chips = []
    for chip in chips:
        if spaced_chips:
            spaced_chips.append(render.Box(width = 1 * scale, height = 2 * scale))
        spaced_chips.append(chip)

    header = render.Row(
        cross_align = "center",
        children = [
            _animated_triangle(scale, top_level, light, tint, len(alerts) > 0),
            render.Box(width = 2 * scale, height = 1),
            render.Text(name, font = small_font, color = light),
        ],
    )

    if alerts:
        body = render.Marquee(
            width = width - 2 * scale,
            child = render.Text(message, font = text_font, color = TEXT_COLOR),
        )
    else:
        body = render.Box(
            width = width - 2 * scale,
            height = 10 * scale,
            child = render.Text(message, font = small_font, color = TEXT_COLOR),
        )

    footer = render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Row(children = spaced_chips) if spaced_chips else render.Box(width = 1, height = 2 * scale),
            render.Text(when, font = tiny_font, color = LABEL_COLOR),
        ],
    )

    return render.Root(
        delay = 50 // scale,
        show_full_animation = True,
        child = render.Box(
            width = width,
            height = height,
            color = tint,
            child = render.Padding(
                pad = (1 * scale, 1 * scale, 1 * scale, 1 * scale),
                child = render.Column(
                    expanded = True,
                    main_align = "space_between",
                    children = [header, body, footer],
                ),
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "orp",
                name = "ORP code (CISORP)",
                desc = "ČHMÚ warning district code of your ORP, e.g. 6107 Náměšť nad Oslavou, 1100 Praha.",
                icon = "locationDot",
                default = "6107",
            ),
            schema.Dropdown(
                id = "language",
                name = "Language",
                desc = "Language of the warning names.",
                icon = "language",
                default = "cs",
                options = [
                    schema.Option(display = "Čeština", value = "cs"),
                    schema.Option(display = "English", value = "en-GB"),
                ],
            ),
            schema.Toggle(
                id = "hide_when_clear",
                name = "Hide when no warnings",
                desc = "Skip the app in rotation while there is no active warning.",
                icon = "eyeSlash",
                default = False,
            ),
        ],
    )

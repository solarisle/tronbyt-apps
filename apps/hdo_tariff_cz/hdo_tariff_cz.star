"""
Applet: HDO Tariff CZ
Summary: EG.D low/high tariff alerts
Description: EG.D Distribuce HDO low (NT) / high (VT) tariff schedule. Warns before VT, counts down VT with a heating-paused note and shows today's NT/VT timeline.
Author: Tronbyt
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "canvas", "render")
load("schema.star", "schema")
load("time.star", "time")

HDO_URL = "https://hdo.distribuce24.cz/casy"
REGION_URL = "https://hdo.distribuce24.cz/region"
CACHE_TTL = 86400
TZ = "Europe/Prague"
DAY = 1440
FRAME_DELAY = 50
LOOP_FRAMES = 40
CODE_FIELDS = ("kodHdo_A", "kodHdo_B", "kodHdo_C", "kodHdo_D", "kodHdo_E")

BG_COLOR = "#000000"
LABEL_COLOR = "#8A8A8A"
TEXT_COLOR = "#FFFFFF"
POINTER_COLOR = "#FFFFFF"
TICK_COLOR = "#5A5A5A"

# state → (accent colour, background tint, timeline colour)
STATES = {
    "nt": ("#00E676", "#001A0B", "#00A152"),
    "soon": ("#FFAB00", "#2A1C00", "#FFAB00"),
    "vt": ("#FF3D3D", "#2E0606", "#FF3D3D"),
}
NT_BAR_COLOR = "#00A152"
VT_BAR_COLOR = "#FF3D3D"

WEEKDAYS = {"Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6, "Sun": 7}

# Czech public holidays with a fixed date; HDO runs the Sunday plan on them
FIXED_HOLIDAYS = [(1, 1), (5, 1), (5, 8), (7, 5), (7, 6), (9, 28), (10, 28), (11, 17), (12, 24), (12, 25), (12, 26)]

TEXTS = {
    "cs": {
        "nt": "Levný tarif",
        "all_nt": "NT celý den",
        "soon": "Nezapínej pračku ani troubu",
        "vt": "Topení stojí, od %s zase topí",
        "to_vt": "do VT",
        "in": "za",
        "left": "zbývá",
    },
    "en": {
        "nt": "Low tariff",
        "all_nt": "NT all day",
        "soon": "Avoid washer and oven",
        "vt": "Heating paused, back at %s",
        "to_vt": "to VT",
        "in": "in",
        "left": "left",
    },
}

MOON = [
    ".###.",
    "##...",
    "##...",
    "##...",
    ".###.",
]
SUN_A = [
    "..#..",
    ".###.",
    "#####",
    ".###.",
    "..#..",
]
SUN_B = [
    "#...#",
    ".###.",
    ".###.",
    ".###.",
    "#...#",
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

def _pulse(i, period):
    # cosine ease 0 → 1 → 0 over one period
    return (1 - math.cos(2 * math.pi * (i % period) / period)) / 2

def _two(n):
    return str(n) if n >= 10 else "0" + str(n)

def _hhmm(minutes):
    m = minutes % DAY
    return "%s:%s" % (_two(m // 60), _two(m % 60))

def _countdown(minutes):
    return "%d:%s" % (minutes // 60, _two(minutes % 60))

def _norm(code):
    return code.upper().replace(" ", "")

def _day(now, offset):
    # noon avoids DST edge cases; time.time normalises day overflow
    return time.time(year = now.year, month = now.month, day = now.day + offset, hour = 12, location = TZ)

def _easter(year):
    # anonymous Gregorian algorithm
    a = year % 19
    b = year // 100
    c = year % 100
    d = b // 4
    e = b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i = c // 4
    k = c % 4
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) // 451
    month = (h + l - 7 * m + 114) // 31
    day = (h + l - 7 * m + 114) % 31 + 1
    return time.time(year = year, month = month, day = day, hour = 12, location = TZ)

def _is_holiday(dt):
    if (dt.month, dt.day) in FIXED_HOLIDAYS:
        return True
    easter = _easter(dt.year)
    for offset in (-2, 1):
        d = time.time(year = easter.year, month = easter.month, day = easter.day + offset, hour = 12, location = TZ)
        if d.month == dt.month and d.day == dt.day:
            return True
    return False

def _day_code(dt):
    return 7 if _is_holiday(dt) else WEEKDAYS[dt.format("Mon")]

def _record_valid(rec, dt):
    od = rec["od"]
    do = rec["do"]
    start = int(od["mesic"]) * 100 + int(od["den"])
    end = int(do["mesic"]) * 100 + int(do["den"])
    md = dt.month * 100 + dt.day
    if int(od["rok"]) >= 9999:
        # repeats every year, may wrap over new year (e.g. 10-01 → 03-31)
        return start <= md and md <= end if start <= end else md >= start or md <= end
    ymd = dt.year * 10000 + md
    return int(od["rok"]) * 10000 + start <= ymd and ymd <= int(do["rok"]) * 10000 + end

def _minutes(hms, is_end):
    m = int(hms[0:2]) * 60 + int(hms[3:5])

    # "23:59:00" (and other :59 ends) means up to the next full minute
    return m + 1 if is_end and hms[3:5] == "59" else m

def _fetch_records(code, psc):
    res = http.get(HDO_URL, ttl_seconds = CACHE_TTL)
    if res.status_code != 200:
        return None
    code = _norm(code)
    matches = [r for r in res.json() if code in [_norm(r.get(f, "")) for f in CODE_FIELDS]]
    regions = {}
    for r in matches:
        regions[r["region"]] = True
    if len(regions) <= 1:
        return matches

    # the same code exists in several regions → pick ours by PSČ
    res = http.get(REGION_URL, ttl_seconds = CACHE_TTL)
    if res.status_code != 200:
        return None
    psc = psc.replace(" ", "")
    region = None
    for row in res.json():
        if row.get("PSC") == psc:
            region = row.get("Region")
            break
    return [r for r in matches if r["region"] == region]

def _nt_intervals(records, now):
    # NT intervals in minutes relative to today's midnight, from yesterday to the day after tomorrow
    raw = []
    for offset in range(-1, 3):
        dt = _day(now, offset)
        code = _day_code(dt)
        for rec in records:
            if not _record_valid(rec, dt):
                continue
            for sazba in rec.get("sazby", []):
                for d in sazba.get("dny", []):
                    if int(d["denVTydnu"]) != code:
                        continue
                    for cas in d.get("casy", []):
                        base = offset * DAY
                        raw.append((base + _minutes(cas["od"], False), base + _minutes(cas["do"], True)))
    merged = []
    for s, e in sorted(raw):
        if merged and s <= merged[-1][1]:
            if e > merged[-1][1]:
                merged[-1] = (merged[-1][0], e)
        else:
            merged.append((s, e))
    return merged

def _vt_intervals(nt):
    vt = []
    cursor = -DAY
    for s, e in nt:
        if s > cursor:
            vt.append((cursor, s))
        cursor = max(cursor, e)
    if cursor < 3 * DAY:
        vt.append((cursor, 3 * DAY))
    return vt

def _sprite(rows, scale, color):
    px = 1 * scale
    out = []
    for row in rows:
        cells = []
        for c in row.elems():
            cells.append(render.Box(width = px, height = px, color = color) if c == "#" else render.Box(width = px, height = px))
        out.append(render.Row(children = cells))
    return render.Column(children = out)

def _animated_icon(state, scale, accent, tint, frames):
    out = []
    for i in range(frames):
        if state == "nt":
            # moon breathes slowly
            out.append(_sprite(MOON, scale, _mix(accent, tint, 0.7 * _pulse(i, frames))))
        elif state == "soon":
            # sun blinks as a warning
            on = (i // (5 * scale)) % 2 == 0
            out.append(_sprite(SUN_A, scale, accent if on else _mix(accent, tint, 0.8)))
        else:
            # sun rays alternate
            out.append(_sprite(SUN_A if (i // (10 * scale)) % 2 == 0 else SUN_B, scale, accent))
    return render.Animation(children = out)

def _timeline(vt, now_m, width, scale, frames):
    # today 00:00–24:00 across the full width; pointer row above the bar marks now and 6/12/18 h
    runs = []
    for x in range(width):
        a = x * DAY // width
        b = (x + 1) * DAY // width
        color = VT_BAR_COLOR if [1 for s, e in vt if s < b and e > a] else NT_BAR_COLOR
        if runs and runs[-1][0] == color:
            runs[-1] = (color, runs[-1][1] + 1)
        else:
            runs.append((color, 1))
    bar = render.Row(children = [render.Box(width = w, height = 2 * scale, color = c) for c, w in runs])

    pointer_x = min(now_m * width // DAY, width - 1)
    ticks = [h * width // 24 for h in (6, 12, 18)]
    out = []
    for i in range(frames):
        on = (i // (frames // 4)) % 2 == 0
        cells = []
        for x in range(width):
            if x == pointer_x:
                color = POINTER_COLOR if on else None
            elif x in ticks:
                color = TICK_COLOR
            else:
                color = None
            cells.append(render.Box(width = 1, height = 1 * scale, color = color) if color else render.Box(width = 1, height = 1 * scale))
        out.append(render.Row(children = cells))
    return render.Column(children = [render.Animation(children = out), bar])

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
    hint_font = "terminus-12" if scale == 2 else "tb-8"
    big_font = "terminus-24" if scale == 2 else "6x13"
    frames = LOOP_FRAMES * scale

    code = config.str("hdo_code", "149").strip()
    psc = config.str("psc", "67573")
    lead = int(config.str("lead", "30"))
    show_always = config.bool("show_always", False)
    texts = TEXTS.get(config.str("language", "cs"), TEXTS["cs"])

    records = _fetch_records(code, psc)
    if records == None:
        return _render_message("No HDO data")
    if not records:
        return _render_message("Unknown HDO code")

    now = time.now().in_location(TZ)
    nt = _nt_intervals(records, now)
    if not nt:
        return _render_message("No HDO schedule")
    vt = _vt_intervals(nt)
    now_m = now.hour * 60 + now.minute

    current = [v for v in vt if v[0] <= now_m and now_m < v[1]]
    upcoming = [v for v in vt if v[0] > now_m and v[0] - now_m < DAY]
    if current:
        state = "vt"
        start, end = current[0]
    elif upcoming and upcoming[0][0] - now_m <= lead:
        state = "soon"
        start, end = upcoming[0]
    elif not show_always:
        return []
    else:
        state = "nt"
        start, end = upcoming[0] if upcoming else (None, None)

    accent, tint, _ = STATES[state]

    if state == "vt":
        header_text = "VT %s-%s" % (_hhmm(start), _hhmm(end))
        big = _countdown(end - now_m)
        big_label = texts["left"]
        hint = texts["vt"] % _hhmm(end)
    elif state == "soon":
        header_text = "VT %s-%s" % (_hhmm(start), _hhmm(end))
        big = _countdown(start - now_m)
        big_label = texts["in"]
        hint = texts["soon"]
    elif start != None:
        header_text = "NT -> VT %s" % _hhmm(start)
        big = _countdown(start - now_m)
        big_label = texts["to_vt"]
        hint = texts["nt"]
    else:
        header_text = "NT"
        big = "NT"
        big_label = ""
        hint = texts["all_nt"]

    header = render.Row(
        cross_align = "center",
        children = [
            _animated_icon(state, scale, accent, tint, frames),
            render.Box(width = 2 * scale, height = 1),
            render.Text(header_text, font = small_font, color = accent),
        ],
    )

    # the last 5 minutes before VT blink
    big_text = render.Text(big, font = big_font, color = accent)
    if state == "soon" and start - now_m <= 5:
        half = frames // 4
        big_text = render.Animation(children = [
            render.Text(big, font = big_font, color = accent if (i // half) % 2 == 0 else tint)
            for i in range(frames)
        ])

    # "za 0:15" reads label first, "0:35 zbývá" / "2:25 do VT" label after
    label = render.Padding(pad = (0, 0, 0, 2 * scale), child = render.Text(big_label, font = small_font, color = LABEL_COLOR))
    spacer = render.Box(width = 2 * scale, height = 1)
    big_row = render.Row(
        cross_align = "end",
        children = [label, spacer, big_text] if state == "soon" else [big_text, spacer, label],
    )

    hint_row = render.Marquee(
        width = width - 2 * scale,
        child = render.Text(hint, font = hint_font, color = TEXT_COLOR),
    )

    return render.Root(
        delay = FRAME_DELAY // scale,
        show_full_animation = True,
        child = render.Box(
            width = width,
            height = height,
            color = tint,
            child = render.Column(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Padding(pad = (1 * scale, 1 * scale, 1 * scale, 0), child = header),
                    render.Padding(pad = (1 * scale, 0, 1 * scale, 0), child = big_row),
                    render.Padding(pad = (1 * scale, 0, 1 * scale, 0), child = hint_row),
                    _timeline(vt, now_m, width, scale, frames),
                ],
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "hdo_code",
                name = "HDO code",
                desc = "Code from your HDO receiver or EG.D portal, e.g. 149 or A1B4DP1.",
                icon = "hashtag",
                default = "149",
            ),
            schema.Text(
                id = "psc",
                name = "PSČ",
                desc = "Postal code, used when the HDO code exists in several EG.D regions.",
                icon = "locationDot",
                default = "67573",
            ),
            schema.Dropdown(
                id = "lead",
                name = "Warn before VT",
                desc = "How early to start showing the VT warning.",
                icon = "clock",
                default = "30",
                options = [
                    schema.Option(display = "15 min", value = "15"),
                    schema.Option(display = "30 min", value = "30"),
                    schema.Option(display = "60 min", value = "60"),
                ],
            ),
            schema.Toggle(
                id = "show_always",
                name = "Show during NT",
                desc = "Also show the app in low tariff. Off = only before and during VT.",
                icon = "eye",
                default = False,
            ),
            schema.Dropdown(
                id = "language",
                name = "Language",
                desc = "Language of the hints.",
                icon = "language",
                default = "cs",
                options = [
                    schema.Option(display = "Čeština", value = "cs"),
                    schema.Option(display = "English", value = "en"),
                ],
            ),
        ],
    )

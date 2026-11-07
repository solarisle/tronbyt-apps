"""
Applet: Czechianews
Summary: Headline news from Czechia
Description: Rotating Czech news headlines from Seznam Zprávy or iRozhlas, with section tags and smooth transitions.
Author: solarisle
"""

load("animation.star", "animation")
load("cache.star", "cache")
load("html.star", "html")
load("http.star", "http")
load("render.star", "canvas", "render")
load("schema.star", "schema")
load("time.star", "time")
load("xpath.star", "xpath")

MEDIA_SEZNAM = "seznam"
MEDIA_IROZHLAS = "irozhlas"

SEZNAM_URL = "https://www.seznamzpravy.cz/"
IROZHLAS_URL = "https://www.irozhlas.cz/rss/irozhlas"
CACHE_TTL = 300
TZ = "Europe/Prague"

# ---- Layout (64 x 32) -------------------------------------------------------
# rows 0-6   header: 7x7 source mark, section tag, publish time
# row  7     progress bar: one segment per headline in this cycle
# rows 8-31  body: 3 lines of tb-8, scrolled vertically when longer
WIDTH = 64
HEADER_H = 7
BODY_H = 24
LINE_H = 8
BODY_LINES = BODY_H // LINE_H
TEXT_X = 1
TEXT_W = WIDTH - TEXT_X  # advance budget per line (last glyph's 1px gap may hang)

# ---- Timeline (milliseconds, converted to frames at the chosen speed) --------
ENTER_MS = 600  # slide up 8px + fade 0.3 -> 1.0, ease_out
EXIT_MS = 400  # slide up 8px + fade 1.0 -> 0.3, ease_in
HOLD_START_MS = 1200  # first 3 lines stay still before scrolling
HOLD_END_MS = 1000  # last 3 lines stay still after scrolling
HOLD_SHORT_MS = 3000  # headline fits in 3 lines: single hold
HOLD_MIN_MS = 800  # floor when even one headline is longer than the dwell time
HOLD_MAX_MS = 4000  # ceiling when spare dwell time is spread over the holds
FADE_FROM = 0.3  # low LED brightness steps are coarse, never fade from 0
POOL_SIZE = 10  # rotate through the top headlines across display cycles
DEFAULT_BUDGET_MS = 15000  # Pixlet < 0.55 has no canvas.max_duration_ms()
NO_LIMIT_BUDGET_MS = 30000  # host sets no ceiling: still keep the WebP small for Gen 1

# Pixlet 0.55 features, with fallbacks so older servers (e.g. PIXLET_VERSION
# v0.50.1) still render: no fade, fixed 15 s timeline.
HAS_FADE = hasattr(animation, "Fade")
HAS_DWELL = hasattr(canvas, "max_duration_ms")

# ---- Colours ----------------------------------------------------------------
TEXT_COLOR = "#FFFFFF"
DIM_COLOR = "#AAAAAA"
FRESH_COLOR = "#FFCC00"
TRACK_COLOR = "#333333"
ERROR_COLOR = "#FF3333"
FRESH_SECONDS = 1800

SOURCES = {
    MEDIA_SEZNAM: {"accent": "#FF2020", "label": "ZPRAVY"},
    MEDIA_IROZHLAS: {"accent": "#00B7EF", "label": "ZPRAVY"},
}

# Section tag from the article URL: (url slug prefix, tag, colour)
SECTIONS = [
    ("zpravy-domov", "DOMOV", "#33AAFF"),
    ("domaci", "DOMOV", "#33AAFF"),
    ("zpravy-svet", "SVET", "#FFCC00"),
    ("zahranicni", "SVET", "#FFCC00"),
    ("volby", "VOLBY", "#FFCC00"),
    ("ekonomika", "EKONOM", "#33FF66"),
    ("sport", "SPORT", "#FF8800"),
    ("kultura", "KULTURA", "#CC66FF"),
    ("veda", "VEDA", "#00E5FF"),
    ("tech", "TECH", "#00E5FF"),
    ("zivotni-styl", "STYL", "#FF66CC"),
    ("komentare", "NAZORY", "#AAAAAA"),
    ("nazory", "NAZORY", "#AAAAAA"),
    ("obrazem", "FOTO", "#AAAAAA"),
]

# 7x7 source marks ("#" = accent, "w" = white, "." = transparent)
ICONS = {
    MEDIA_SEZNAM: [
        ".#####.",
        "##.....",
        "##.....",
        ".#####.",
        ".....##",
        ".....##",
        ".#####.",
    ],
    MEDIA_IROZHLAS: [
        "#######",
        "#wwww##",
        "#######",
        "#www###",
        "#######",
        "#wwwww#",
        "#######",
    ],
}

# tb-8 glyph advances (px) that differ from the default 5, from fonts/tb-8.bdf
TB8_WIDTHS = {
    " ": 3,
    "!": 2,
    "\"": 4,
    "'": 2,
    "(": 3,
    ")": 3,
    "+": 4,
    ",": 3,
    "-": 4,
    ".": 2,
    ":": 2,
    ";": 3,
    "<": 4,
    "=": 4,
    ">": 4,
    "?": 4,
    "@": 6,
    "I": 4,
    "J": 4,
    "M": 6,
    "T": 4,
    "V": 6,
    "W": 6,
    "Y": 6,
    "^": 4,
    "`": 3,
    "c": 4,
    "i": 4,
    "j": 4,
    "l": 4,
    "m": 6,
    "s": 4,
    "v": 4,
    "w": 6,
    "|": 2,
}

# ---- Text helpers -----------------------------------------------------------

def _clean(text):
    text = text.replace(" ", " ").replace("\n", " ").replace("\t", " ")
    return " ".join([w for w in text.split(" ") if w])

def _text_width(text):
    total = 0
    for ch in text.codepoints():
        total += TB8_WIDTHS.get(ch, 5)
    return total

def _split_long_word(word):
    """Break a word wider than a line into line-sized pieces (by codepoint)."""
    pieces = []
    current = ""
    for ch in word.codepoints():
        if current and _text_width(current + ch) > TEXT_W:
            pieces.append(current)
            current = ch
        else:
            current += ch
    if current:
        pieces.append(current)
    return pieces

def wrap_lines(text):
    """Word-wrap by real tb-8 pixel widths so no line is clipped."""
    lines = []
    current = ""
    for word in text.split(" "):
        if not word:
            continue
        candidate = word if not current else current + " " + word
        if _text_width(candidate) <= TEXT_W:
            current = candidate
            continue
        if current:
            lines.append(current)
            current = ""
        if _text_width(word) <= TEXT_W:
            current = word
        else:
            pieces = _split_long_word(word)
            lines.extend(pieces[:-1])
            current = pieces[-1]
    if current:
        lines.append(current)
    return lines

def _section(url):
    slug = url
    for prefix in ["https://www.irozhlas.cz/", "https://www.seznamzpravy.cz/clanek/"]:
        if slug.startswith(prefix):
            slug = slug[len(prefix):]
    for prefix, tag, color in SECTIONS:
        if slug.startswith(prefix):
            return tag, color
    return None, None

# ---- Data -------------------------------------------------------------------

def parse_seznam(body):
    items = []
    links = html(body).find("a[data-dot='mol-article-card-title']")
    for i in range(links.len()):
        link = links.eq(i)
        title = _clean(link.find("h3").text())
        if not title:
            continue
        tag, color = _section(link.attr("href") or "")
        items.append({"title": title, "tag": tag, "tag_color": color, "time": None})
        if len(items) >= POOL_SIZE:
            break

    # Fallback for markup changes: any <h3> on the page.
    if not items:
        heads = html(body).find("h3")
        for i in range(min(heads.len(), POOL_SIZE)):
            title = _clean(heads.eq(i).text())
            if title:
                items.append({"title": title, "tag": None, "tag_color": None, "time": None})
    return items

def parse_irozhlas(body):
    doc = xpath.loads(body)
    titles = doc.query_all("/rss/channel/item/title")
    links = doc.query_all("/rss/channel/item/link")
    dates = doc.query_all("/rss/channel/item/pubDate")
    items = []
    for i in range(min(len(titles), POOL_SIZE)):
        title = _clean(titles[i])
        if not title:
            continue
        tag, color = _section(links[i].strip() if i < len(links) else "")
        published = None
        if i < len(dates) and dates[i].strip():
            published = time.parse_time(dates[i].strip(), "Mon, 02 Jan 2006 15:04:05 -0700")
        items.append({"title": title, "tag": tag, "tag_color": color, "time": published})
    return items

# ---- Timeline planning -----------------------------------------------------

def _frames(ms, delay):
    return max(1, ms // delay)

def _plan_card(item, delay):
    lines = wrap_lines(item["title"])
    overflow = max(0, len(lines) * LINE_H - BODY_H)
    if overflow:
        hold_a, hold_b = _frames(HOLD_START_MS, delay), _frames(HOLD_END_MS, delay)
    else:
        hold_a, hold_b = _frames(HOLD_SHORT_MS, delay), 0
    return {
        "item": item,
        "lines": lines,
        "overflow": overflow,
        "enter": _frames(ENTER_MS, delay),
        "exit": _frames(EXIT_MS, delay),
        "hold_a": hold_a,
        "hold_b": hold_b,
    }

def _card_frames(card):
    return card["enter"] + card["hold_a"] + card["overflow"] + card["hold_b"] + card["exit"]

def _budget_ms():
    if not HAS_DWELL:
        return DEFAULT_BUDGET_MS
    budget_ms = canvas.max_duration_ms()
    return budget_ms if budget_ms > 0 else NO_LIMIT_BUDGET_MS

def plan_cards(items, delay):
    """Fit as many headlines as the host's dwell time allows (Pixlet 0.55+)."""
    cards = [_plan_card(item, delay) for item in items]
    budget = _budget_ms() // delay
    chosen = []
    used = 0
    for card in cards:
        f = _card_frames(card)
        if chosen and used + f > budget:
            break
        chosen.append(card)
        used += f

    if used > budget:
        # A single long headline: shorten its holds; the device loops what fits.
        card = chosen[0]
        floor = _frames(HOLD_MIN_MS, delay)
        card["hold_a"] = min(card["hold_a"], floor)
        if card["hold_b"]:
            card["hold_b"] = min(card["hold_b"], floor)
        return chosen

    # Spread spare dwell time over the holds so the loop doesn't restart early.
    cap = _frames(HOLD_MAX_MS, delay)
    extra = (budget - used) // len(chosen)
    for card in chosen:
        if card["overflow"]:
            card["hold_a"] = min(cap, card["hold_a"] + extra // 2)
            card["hold_b"] = min(cap, card["hold_b"] + extra - extra // 2)
        else:
            card["hold_a"] = min(cap, card["hold_a"] + extra)
    return chosen

def rotate(items, source):
    """Start each display cycle where the previous one stopped."""
    key = "czechianews_cursor_" + source
    cursor = cache.get(key)
    start = int(cursor) % len(items) if cursor and cursor.isdigit() else 0
    return items[start:] + items[:start], key, start

# ---- Widgets ----------------------------------------------------------------

def _icon(source):
    accent = SOURCES[source]["accent"]
    rows = []
    for line in ICONS[source]:
        pixels = []
        for ch in line.elems():
            if ch == "#":
                pixels.append(render.Box(width = 1, height = 1, color = accent))
            elif ch == "w":
                pixels.append(render.Box(width = 1, height = 1, color = TEXT_COLOR))
            else:
                pixels.append(render.Box(width = 1, height = 1))
        rows.append(render.Row(children = pixels))
    return render.Column(children = rows)

def _header(source, item, now):
    tag = item["tag"] or SOURCES[source]["label"]
    tag_color = item["tag_color"] or DIM_COLOR
    right = []
    if item["time"]:
        age = now.unix - item["time"].unix
        right.append(render.Padding(
            pad = (0, 1, 0, 0),
            child = render.Text(
                item["time"].in_location(TZ).format("15:04"),
                font = "tom-thumb",
                color = FRESH_COLOR if age < FRESH_SECONDS else DIM_COLOR,
            ),
        ))
    return render.Box(
        width = WIDTH,
        height = HEADER_H,
        child = render.Row(
            expanded = True,
            main_align = "space_between",
            children = [
                render.Row(children = [
                    _icon(source),
                    render.Box(width = 2, height = HEADER_H),
                    render.Padding(
                        pad = (0, 1, 0, 0),
                        child = render.Text(tag, font = "tom-thumb", color = tag_color),
                    ),
                ]),
            ] + right,
        ),
    )

def _progress(count, index, frames, accent):
    """One segment per headline; the current one fills over the card's time."""
    gaps = count - 1
    base = (WIDTH - gaps) // count
    spare = WIDTH - gaps - base * count
    children = []
    for i in range(count):
        w = base + (1 if i < spare else 0)
        if i < index:
            seg = render.Box(width = w, height = 1, color = accent)
        elif i > index:
            seg = render.Box(width = w, height = 1, color = TRACK_COLOR)
        else:
            seg = render.Stack(children = [
                render.Box(width = w, height = 1, color = TRACK_COLOR),
                animation.Transformation(
                    child = render.Box(width = w, height = 1, color = accent),
                    width = w,
                    height = 1,
                    duration = frames,
                    keyframes = [
                        animation.Keyframe(0.0, [animation.Translate(-w, 0)]),
                        animation.Keyframe(1.0, [animation.Translate(0, 0)]),
                    ],
                ),
            ])
        children.append(seg)
        if i < count - 1:
            children.append(render.Box(width = 1, height = 1))
    return render.Row(children = children)

def _keyframe(at, total, y, fade, curve = "linear", shift = 0):
    return animation.Keyframe(
        percentage = at * 1.0 / total,
        transforms = [animation.Translate(0, y + shift)] + ([animation.Fade(fade)] if HAS_FADE else []),
        curve = curve,
    )

def _body(card, frames, color):
    # Enter: slide up from +8 with fade in -> hold -> scroll 1px/frame -> hold
    # -> exit: slide up 8 more with fade out. Ends where the next card starts.
    overflow = card["overflow"]
    t_in = card["enter"]
    t_scroll = t_in + card["hold_a"]
    t_scrolled = t_scroll + overflow
    t_out = frames - card["exit"]

    # The 24px Box clips the body but centres a taller child; undo the centring.
    canvas_h = max(BODY_H, len(card["lines"]) * LINE_H)
    shift = (canvas_h - BODY_H) // 2
    keyframes = [
        _keyframe(0, frames, LINE_H, FADE_FROM, "ease_out", shift = shift),
        _keyframe(t_in, frames, 0, 1.0, shift = shift),
        _keyframe(t_scroll, frames, 0, 1.0, shift = shift),
    ]
    if overflow:
        keyframes.append(_keyframe(t_scrolled, frames, -overflow, 1.0, shift = shift))
    if t_out > t_scrolled:
        keyframes.append(_keyframe(t_out, frames, -overflow, 1.0, "ease_in", shift = shift))
    keyframes.append(_keyframe(frames, frames, -overflow - LINE_H, FADE_FROM, shift = shift))

    lines = render.Column(children = [
        render.Padding(
            pad = (TEXT_X, 0, 0, 0),
            child = render.Text(line, font = "tb-8", color = color),
        )
        for line in card["lines"]
    ])
    return render.Box(
        width = WIDTH,
        height = BODY_H,
        child = animation.Transformation(
            child = lines,
            width = WIDTH,
            height = canvas_h,
            duration = frames,
            keyframes = keyframes,
        ),
    )

def _scene(source, card, index, count, color, now):
    frames = _card_frames(card)

    # animation.Fade (Pixlet 0.55) draws outside the parent Box's clip, so the
    # scrolling body would bleed into the header. Paint the header last, on an
    # opaque black backing, so it always covers the body.
    return render.Stack(children = [
        render.Padding(
            pad = (0, HEADER_H + 1, 0, 0),
            child = _body(card, frames, color),
        ),
        render.Box(
            width = WIDTH,
            height = HEADER_H + 1,
            color = "#000000",
            child = render.Column(children = [
                _header(source, card["item"], now),
                _progress(count, index, frames, SOURCES[source]["accent"]),
            ]),
        ),
    ])

def _message(source, title, detail):
    return render.Root(
        child = render.Column(children = [
            render.Row(children = [
                _icon(source),
                render.Box(width = 2, height = HEADER_H),
                render.Padding(pad = (0, 1, 0, 0), child = render.Text("ZPRAVY", font = "tom-thumb", color = DIM_COLOR)),
            ]),
            render.Box(width = WIDTH, height = 1, color = TRACK_COLOR),
            render.Box(
                width = WIDTH,
                height = BODY_H,
                child = render.Column(
                    cross_align = "center",
                    children = [
                        render.Text(title, font = "tb-8", color = ERROR_COLOR),
                        render.Text(detail, font = "tom-thumb", color = DIM_COLOR),
                    ],
                ),
            ),
        ]),
    )

# ---- Main -------------------------------------------------------------------

def main(config):
    source = config.str("media_source", MEDIA_SEZNAM)
    if source not in SOURCES:
        source = MEDIA_SEZNAM
    delay = int(config.str("text_speed", "100"))
    color = config.str("font_color", TEXT_COLOR)

    url = SEZNAM_URL if source == MEDIA_SEZNAM else IROZHLAS_URL
    response = http.get(url, ttl_seconds = CACHE_TTL)
    if response.status_code != 200:
        return _message(source, "Nedostupné", "HTTP %d" % response.status_code)

    if source == MEDIA_SEZNAM:
        items = parse_seznam(response.body())
    else:
        items = parse_irozhlas(response.body())
    if not items:
        return _message(source, "Žádné zprávy", "no headlines")

    ordered, cursor_key, start = rotate(items, source)
    cards = plan_cards(ordered, delay)
    cache.set(cursor_key, str((start + len(cards)) % len(items)), ttl_seconds = 86400)

    now = time.now()
    scenes = [
        _scene(source, card, i, len(cards), color, now)
        for i, card in enumerate(cards)
    ]
    return render.Root(
        delay = delay,
        child = render.Sequence(children = scenes),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "media_source",
                name = "Media Source",
                desc = "Select your favorite news source.",
                icon = "newspaper",
                default = MEDIA_SEZNAM,
                options = [
                    schema.Option(display = "seznamzpravy.cz", value = MEDIA_SEZNAM),
                    schema.Option(display = "irozhlas.cz", value = MEDIA_IROZHLAS),
                ],
            ),
            schema.Dropdown(
                id = "text_speed",
                name = "Scroll Speed",
                desc = "How fast long headlines scroll (1 px per frame).",
                icon = "personRunning",
                default = "100",
                options = [
                    schema.Option(display = "Fast", value = "50"),
                    schema.Option(display = "Normal", value = "100"),
                    schema.Option(display = "Slow", value = "150"),
                ],
            ),
            schema.Color(
                id = "font_color",
                name = "Headline Color",
                desc = "Color of the headline text.",
                icon = "brush",
                default = TEXT_COLOR,
            ),
        ],
    )

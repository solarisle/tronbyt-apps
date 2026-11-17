"""
Applet: Google Review
Summary: Display Google Maps reviews
Description: Rotates the newest Google Maps reviews of a place with star rating, age, reviewer and text. Can show only reviews from the last N days and hide itself when there are none.
Author: solarisle
"""

load("animation.star", "animation")
load("cache.star", "cache")
load("http.star", "http")
load("render.star", "canvas", "render")
load("schema.star", "schema")
load("time.star", "time")

API_URL = "https://serpapi.com/search.json?engine=google_maps_reviews&sort_by=newestFirst&data_id=%s&hl=%s&api_key=%s"
CACHE_TTL = 43200  # 12 h: SerpAPI free plan has 100 searches per month
POOL_SIZE = 8  # one SerpAPI page of newest reviews

# ---- Layout (64 x 32) -------------------------------------------------------
# rows 0-6   header: five 5x5 stars, age of the review (or place rating)
# row  7     progress bar: one segment per card in this cycle
# rows 8-31  body: reviewer name, then the review text in tb-8, scrolled
WIDTH = 64
HEADER_H = 7
BODY_H = 24
LINE_H = 8
TEXT_X = 1
TEXT_W = WIDTH - TEXT_X

# ---- Timeline (milliseconds, converted to frames at the chosen speed) --------
ENTER_MS = 600
EXIT_MS = 400
HOLD_START_MS = 1200
HOLD_END_MS = 1000
HOLD_SHORT_MS = 3000
HOLD_INTRO_MS = 1500
HOLD_MIN_MS = 800
HOLD_MAX_MS = 4000
FADE_FROM = 0.3
DEFAULT_BUDGET_MS = 15000
NO_LIMIT_BUDGET_MS = 30000

HAS_FADE = hasattr(animation, "Fade")
HAS_DWELL = hasattr(canvas, "max_duration_ms")

# ---- Colours ----------------------------------------------------------------
ACCENT = "#4285F4"  # Google blue
STAR_ON = "#FBBC04"  # Google yellow
STAR_OFF = "#3A3A3A"
TEXT_COLOR = "#FFFFFF"
NAME_COLOR = "#FFB74D"
DIM_COLOR = "#8A8A8A"
FRESH_COLOR = "#FBBC04"
TRACK_COLOR = "#333333"
ERROR_COLOR = "#FF3333"
LOGO_COLORS = ["#4285F4", "#EA4335", "#FBBC04", "#4285F4", "#34A853", "#EA4335"]

STAR = [
    "..#..",
    ".###.",
    "#####",
    ".###.",
    ".#.#.",
]

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
    text = text.replace(" ", " ").replace("\n", " ").replace("\r", " ").replace("\t", " ")
    return " ".join([w for w in text.split(" ") if w])

def _text_width(text):
    total = 0
    for ch in text.codepoints():
        total += TB8_WIDTHS.get(ch, 5)
    return total

def _split_long_word(word):
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

def _one_line(text):
    lines = wrap_lines(text)
    if not lines:
        return ""
    if len(lines) == 1:
        return lines[0]
    chars = list(lines[0].codepoints())
    for _ in range(len(chars)):
        if _text_width("".join(chars) + "..") <= TEXT_W:
            break
        chars = chars[:-1]
    return "".join(chars) + ".."

def _one_decimal(value):
    tenths = int(value * 10 + 0.5)
    return "%d.%d" % (tenths // 10, tenths % 10)

# ---- Data -------------------------------------------------------------------

def _parse_time(iso):
    """SerpAPI iso_date is RFC3339 UTC, e.g. "2026-07-17T18:00:57Z"."""
    if not iso or len(iso) < 20:
        return None
    return time.parse_time(iso)

def _age(seconds):
    if seconds < 3600:
        return "%dm" % max(1, seconds // 60)
    if seconds < 86400:
        return "%dh" % (seconds // 3600)
    if seconds < 86400 * 365:
        return "%dd" % (seconds // 86400)
    return "%dy" % (seconds // (86400 * 365))

def parse_reviews(data, now, days):
    """Newest reviews, optionally only those from the last `days` days."""
    items = []
    for review in data.get("reviews", [])[:POOL_SIZE]:
        posted = _parse_time(review.get("iso_date", ""))
        age = now.unix - posted.unix if posted else None
        if days > 0 and (age == None or age > days * 86400):
            continue
        rating = review.get("rating") or 0
        items.append({
            "rating": int(rating),
            "age": age,
            "date": review.get("date", ""),
            "user": _clean((review.get("user") or {}).get("name", "") or "Anonymous"),
            "text": _clean(review.get("snippet", "") or ""),
        })
    return items

def rotate(items, data_id):
    """Start each display cycle where the previous one stopped."""
    key = "google_review_cursor_" + data_id
    cursor = cache.get(key)
    start = int(cursor) % len(items) if cursor and cursor.isdigit() else 0
    return items[start:] + items[:start], key, start

# ---- Timeline planning -----------------------------------------------------

def _frames(ms, delay):
    return max(1, ms // delay)

def _make_card(kind, lines, data, delay, short_ms):
    overflow = max(0, len(lines) * LINE_H - BODY_H)
    if overflow:
        hold_a, hold_b = _frames(HOLD_START_MS, delay), _frames(HOLD_END_MS, delay)
    else:
        hold_a, hold_b = _frames(short_ms, delay), 0
    return {
        "kind": kind,
        "data": data,
        "lines": lines,
        "overflow": overflow,
        "enter": _frames(ENTER_MS, delay),
        "exit": _frames(EXIT_MS, delay),
        "hold_a": hold_a,
        "hold_b": hold_b,
    }

def _review_card(item, delay):
    lines = [(_one_line(item["user"]), NAME_COLOR)]
    if item["text"]:
        lines += [(line, TEXT_COLOR) for line in wrap_lines(item["text"])]
    else:
        lines.append(("(no text)", DIM_COLOR))
    return _make_card("review", lines, item, delay, HOLD_SHORT_MS)

def _intro_card(place, delay):
    lines = [(line, TEXT_COLOR) for line in wrap_lines(place["title"])[:3]]
    return _make_card("intro", lines, place, delay, HOLD_INTRO_MS)

def _card_frames(card):
    return card["enter"] + card["hold_a"] + card["overflow"] + card["hold_b"] + card["exit"]

def _budget_ms():
    if not HAS_DWELL:
        return DEFAULT_BUDGET_MS
    budget_ms = canvas.max_duration_ms()
    return budget_ms if budget_ms > 0 else NO_LIMIT_BUDGET_MS

def plan_cards(cards, delay):
    """Fit as many cards as the host's dwell time allows; the first always stays."""
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
        floor = _frames(HOLD_MIN_MS, delay)
        for card in chosen:
            card["hold_a"] = min(card["hold_a"], floor)
            if card["hold_b"]:
                card["hold_b"] = min(card["hold_b"], floor)
        return chosen

    cap = _frames(HOLD_MAX_MS, delay)
    extra = (budget - used) // len(chosen)
    for card in chosen:
        if card["overflow"]:
            card["hold_a"] = min(cap, card["hold_a"] + extra // 2)
            card["hold_b"] = min(cap, card["hold_b"] + extra - extra // 2)
        else:
            card["hold_a"] = min(cap, card["hold_a"] + extra)
    return chosen

# ---- Widgets ----------------------------------------------------------------

def _bitmap(rows, color):
    out = []
    for line in rows:
        out.append(render.Row(children = [
            render.Box(width = 1, height = 1, color = color if ch == "#" else None)
            for ch in line.elems()
        ]))
    return render.Column(children = out)

def _stars(rating):
    children = []
    for i in range(5):
        if i:
            children.append(render.Box(width = 1, height = 5))
        children.append(_bitmap(STAR, STAR_ON if i < rating else STAR_OFF))
    return render.Padding(pad = (0, 1, 0, 0), child = render.Row(children = children))

def _small(text, color):
    return render.Padding(
        pad = (0, 1, 0, 0),
        child = render.Text(text, font = "tom-thumb", color = color),
    )

def _header(card):
    data = card["data"]
    if card["kind"] == "intro":
        stars = int(data["rating"] + 0.5)
        right = _small(_one_decimal(data["rating"]) if data["rating"] else "", STAR_ON)
    else:
        stars = data["rating"]
        if data["age"] != None:
            fresh = data["age"] < 86400
            right = _small("NEW" if data["age"] < 3600 else _age(data["age"]), FRESH_COLOR if fresh else DIM_COLOR)
        else:
            right = _small("", DIM_COLOR)
    return render.Box(
        width = WIDTH,
        height = HEADER_H,
        child = render.Row(
            expanded = True,
            main_align = "space_between",
            children = [_stars(stars), right],
        ),
    )

def _progress(count, index, frames):
    gaps = count - 1
    base = (WIDTH - gaps) // count
    spare = WIDTH - gaps - base * count
    children = []
    for i in range(count):
        w = base + (1 if i < spare else 0)
        if i < index:
            seg = render.Box(width = w, height = 1, color = ACCENT)
        elif i > index:
            seg = render.Box(width = w, height = 1, color = TRACK_COLOR)
        else:
            seg = render.Stack(children = [
                render.Box(width = w, height = 1, color = TRACK_COLOR),
                animation.Transformation(
                    child = render.Box(width = w, height = 1, color = ACCENT),
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

def _body(card, frames):
    overflow = card["overflow"]
    t_in = card["enter"]
    t_scroll = t_in + card["hold_a"]
    t_scrolled = t_scroll + overflow
    t_out = frames - card["exit"]

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

    if card["kind"] == "intro":
        # Place name centred in the body; first line pushed down when it is short.
        top = (BODY_H - len(card["lines"]) * LINE_H) // 2
        content = render.Padding(
            pad = (0, top, 0, 0),
            child = render.Column(
                cross_align = "center",
                children = [
                    render.Box(width = WIDTH, height = LINE_H, child = render.Text(text, font = "tb-8", color = color))
                    for text, color in card["lines"]
                ],
            ),
        )
    else:
        content = render.Column(children = [
            render.Padding(pad = (TEXT_X, 0, 0, 0), child = render.Text(text, font = "tb-8", color = color))
            for text, color in card["lines"]
        ])

    return render.Box(
        width = WIDTH,
        height = BODY_H,
        child = animation.Transformation(
            child = content,
            width = WIDTH,
            height = canvas_h,
            duration = frames,
            keyframes = keyframes,
        ),
    )

def _scene(card, index, count):
    frames = _card_frames(card)

    # animation.Fade draws outside the parent Box's clip: paint the header last,
    # on an opaque backing, so the scrolling body never bleeds into it.
    return render.Stack(children = [
        render.Padding(pad = (0, HEADER_H + 1, 0, 0), child = _body(card, frames)),
        render.Box(
            width = WIDTH,
            height = HEADER_H + 1,
            color = "#000000",
            child = render.Column(children = [
                _header(card),
                _progress(count, index, frames),
            ]),
        ),
    ])

def _logo():
    return render.Row(children = [
        render.Text(ch, font = "tom-thumb", color = LOGO_COLORS[i])
        for i, ch in enumerate("Google".elems())
    ])

def _message(title, detail):
    return render.Root(
        child = render.Column(children = [
            render.Padding(pad = (1, 1, 0, 0), child = render.Box(width = WIDTH - 1, height = HEADER_H - 1, child = render.Row(expanded = True, children = [_logo()]))),
            render.Box(width = WIDTH, height = 1, color = TRACK_COLOR),
            render.Box(
                width = WIDTH,
                height = BODY_H,
                child = render.Column(
                    cross_align = "center",
                    children = [
                        render.Text(title, font = "tb-8", color = ERROR_COLOR),
                        render.WrappedText(detail, font = "tom-thumb", color = DIM_COLOR, width = WIDTH - 2, align = "center"),
                    ],
                ),
            ),
        ]),
    )

# ---- Main -------------------------------------------------------------------

def _days(config):
    raw = config.str("days", "0").strip()
    return int(raw) if raw.isdigit() else 0

def main(config):
    api_key = config.str("api_key", "")
    data_id = config.str("data_id", "")
    hl = config.str("language", "") or "en"
    delay = int(config.str("text_speed", "100"))
    days = _days(config)

    if not api_key:
        return _message("No API key", "Set your SerpAPI key")
    if not data_id:
        return _message("No place", "Set the place data_id")

    response = http.get(API_URL % (data_id, hl, api_key), ttl_seconds = CACHE_TTL)
    if response.status_code != 200:
        return _message("Unavailable", "HTTP %d" % response.status_code)
    data = response.json()
    if data.get("error"):
        return _message("API error", data["error"])

    now = time.now()
    items = parse_reviews(data, now, days)
    if not items:
        if days > 0:
            return []  # nothing new in the window: skip this app in the rotation
        return _message("No reviews", "for this place")

    place_info = data.get("place_info") or {}
    place = {
        "title": _clean(place_info.get("title", "") or "Google Review"),
        "rating": float(place_info.get("rating") or 0),
    }

    ordered, cursor_key, start = rotate(items, data_id)
    cards = [_intro_card(place, delay)] + [_review_card(item, delay) for item in ordered]
    cards = plan_cards(cards, delay)
    shown = len(cards) - 1  # the intro is not a review
    cache.set(cursor_key, str((start + max(1, shown)) % len(items)), ttl_seconds = 86400)

    return render.Root(
        delay = delay,
        child = render.Sequence(children = [
            _scene(card, i, len(cards))
            for i, card in enumerate(cards)
        ]),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "api_key",
                name = "SerpAPI Key",
                desc = "Your SerpAPI key (serpapi.com/manage-api-key).",
                icon = "key",
                secret = True,
            ),
            schema.Text(
                id = "data_id",
                name = "Google Maps Place ID",
                desc = "Google Maps data_id from SerpAPI search results.",
                icon = "mapPin",
            ),
            schema.Text(
                id = "language",
                name = "Language",
                desc = "Language code for reviews (e.g. en, ja, fr). Defaults to en.",
                icon = "language",
            ),
            schema.Text(
                id = "days",
                name = "Only Last N Days",
                desc = "Show only reviews from the last N days and hide the app when there are none. 0 shows the newest reviews.",
                icon = "calendarDays",
                default = "0",
            ),
            schema.Dropdown(
                id = "text_speed",
                name = "Scroll Speed",
                desc = "How fast long reviews scroll (1 px per frame).",
                icon = "personRunning",
                default = "100",
                options = [
                    schema.Option(display = "Fast", value = "50"),
                    schema.Option(display = "Normal", value = "100"),
                    schema.Option(display = "Slow", value = "150"),
                ],
            ),
        ],
    )

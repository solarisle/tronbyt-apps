"""
Applet: Spot Price CZ
Summary: Czech spot electricity price light
Description: Current 15-minute OTE spot electricity price with a green/yellow/red level light, today's rank and the next 4 hours.
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
NEXT_SLOTS = 16

BG_COLOR = "#000000"
LABEL_COLOR = "#8A8A8A"
NOW_MARK_COLOR = "#FFFFFF"

# level → (light colour, dim background tint)
LEVELS = {
    "low": ("#00E676", "#002A12"),
    "medium": ("#FFD600", "#2A2400"),
    "high": ("#FF3D3D", "#2E0606"),
}

def _level_colors(level):
    return LEVELS.get(level, ("#9E9E9E", "#1A1A1A"))

def _format_price(value):
    # Czech decimal comma, 2 decimals, handles negative prices
    cents = int(math.round(value * 100))
    sign = "-" if cents < 0 else ""
    cents = -cents if cents < 0 else cents
    frac = str(cents % 100)
    if len(frac) < 2:
        frac = "0" + frac
    return "%s%d,%s" % (sign, cents // 100, frac)

def _two(n):
    return str(n) if n >= 10 else "0" + str(n)

def _kwh_price(slot, markup, with_vat):
    # API price is CZK/MWh
    value = slot["priceCZK"] / 1000.0 + markup
    return value * VAT if with_vat else value

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

def _render_message(msg):
    return render.Root(
        child = render.Box(
            color = BG_COLOR,
            child = render.WrappedText(msg, font = "tom-thumb", color = LABEL_COLOR, align = "center"),
        ),
    )

def _bar_chart(upcoming, scale):
    # upcoming: list of (price, level); the first one is the current slot
    bar_w = 3 * scale
    gap = 1 * scale
    max_h = 7 * scale
    prices = [p for p, _ in upcoming]
    lo = min(prices)
    hi = max(prices)
    span = hi - lo
    bars = []
    for i, (price, level) in enumerate(upcoming):
        if span > 0:
            h = 1 * scale + int((price - lo) * 1.0 / span * (max_h - 1 * scale))
        else:
            h = max_h // 2
        color = _level_colors(level)[0]
        column = [render.Box(width = bar_w, height = max_h - h)]
        if i == 0:
            # current slot: white cap on top of the bar
            column.append(render.Box(width = bar_w, height = 1 * scale, color = NOW_MARK_COLOR))
            column.append(render.Box(width = bar_w, height = max(h - 1 * scale, 0), color = color))
        else:
            column.append(render.Box(width = bar_w, height = h, color = color))
        bars.append(render.Column(children = column))
        if i < len(upcoming) - 1:
            bars.append(render.Box(width = gap, height = max_h))
    return render.Row(children = bars)

def main(config):
    scale = 2 if canvas.is2x() else 1
    width, height = canvas.size()
    small_font = "terminus-12" if scale == 2 else "tom-thumb"
    big_font = "terminus-24" if scale == 2 else "6x13"

    markup_str = config.str("markup", "0").replace(",", ".")
    markup = float(markup_str) if markup_str.replace(".", "", 1).replace("-", "", 1).isdigit() else 0.0
    with_vat = config.bool("with_vat", False)

    data = _fetch_prices()
    if data == None or not data.get("hoursToday"):
        return _render_message("No price data")

    today = data["hoursToday"]
    tomorrow = data.get("hoursTomorrow") or []
    now = time.now().in_location(TZ)
    idx = _find_slot(today, now.hour, (now.minute // 15) * 15)
    if idx < 0:
        return _render_message("No current slot")

    current = today[idx]
    level = current.get("level", "")
    light, tint = _level_colors(level)
    price = _kwh_price(current, markup, with_vat)
    rank = int(current.get("levelNum96", 0))

    upcoming = []
    for s in (today[idx:] + tomorrow)[:NEXT_SLOTS]:
        upcoming.append((_kwh_price(s, markup, with_vat), s.get("level", "")))

    header = render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Row(
                cross_align = "center",
                children = [
                    render.Circle(diameter = 5 * scale, color = light),
                    render.Box(width = 2 * scale, height = 1),
                    render.Text("%s:%s" % (_two(int(current["hour"])), _two(int(current["minute"]))), font = small_font, color = LABEL_COLOR),
                ],
            ),
            render.Text("#%d/%d" % (rank, len(today)), font = small_font, color = light),
        ],
    )

    price_row = render.Row(
        cross_align = "end",
        children = [
            render.Text(_format_price(price), font = big_font, color = light),
            render.Box(width = 2 * scale, height = 1),
            render.Text("Kč", font = small_font if scale == 2 else "5x8", color = LABEL_COLOR),
        ],
    )

    return render.Root(
        child = render.Box(
            width = width,
            height = height,
            color = tint,
            child = render.Padding(
                pad = (1 * scale, 1 * scale, 1 * scale, 0),
                child = render.Column(
                    expanded = True,
                    main_align = "space_between",
                    cross_align = "center",
                    children = [
                        header,
                        price_row,
                        _bar_chart(upcoming, scale),
                    ],
                ),
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "markup",
                name = "Markup (Kč/kWh)",
                desc = "Optional amount added to the spot price, e.g. your supplier fee and distribution.",
                icon = "plus",
                default = "0",
            ),
            schema.Toggle(
                id = "with_vat",
                name = "Include VAT (21 %)",
                desc = "Multiply the price by 1.21.",
                icon = "percent",
                default = False,
            ),
        ],
    )

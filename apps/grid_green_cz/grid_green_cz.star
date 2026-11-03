"""
Applet: Grid Green CZ
Summary: Czech grid renewable share
Description: Live Czech generation mix from ČEPS: renewable (OZE) share, estimated CO2 intensity and a stacked bar of the generation sources.
Author: Tronbyt
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "canvas", "render")
load("schema.star", "schema")
load("time.star", "time")
load("xpath.star", "xpath")

CEPS_URL = "https://www.ceps.cz/_layouts/CepsData.asmx"
SOAP_ACTION = "https://www.ceps.cz/CepsData/Generation"
CACHE_TTL = 600
TZ = "Europe/Prague"

SOAP_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>
<Generation xmlns="https://www.ceps.cz/CepsData/"><dateFrom>%s</dateFrom><dateTo>%s</dateTo><agregation>QH</agregation><function>AVG</function><version>RT</version><para1>all</para1></Generation>
</soap:Body></soap:Envelope>"""

# ČEPS series → (key, colour, renewable, low carbon, est. tCO2/MWh)
SOURCES = [
    ("value3", "NUC", "#B388FF", False, True, 0.0),  # NPP nuclear
    ("value1", "COAL", "#8D6E63", False, False, 0.95),  # TPP thermal (mostly lignite)
    ("value2", "GAS", "#FF9100", False, False, 0.37),  # CCGT
    ("value6", "BIO", "#7CB342", True, True, 0.0),  # AltPP biomass/biogas
    ("value4", "HYD", "#2979FF", True, True, 0.0),  # HPP hydro
    ("value8", "WIND", "#18FFFF", True, True, 0.0),  # WPP wind
    ("value9", "SUN", "#FFEA00", True, True, 0.0),  # PVPP solar
    ("value5", "PS", "#5C6BC0", False, False, 0.0),  # PsPP pumped storage
    ("value7", "OTH", "#616161", False, False, 0.0),  # ApPP other
]

BG_COLOR = "#000000"
LABEL_COLOR = "#8A8A8A"
TEXT_COLOR = "#E0E0E0"

def _two(n):
    return str(n) if n >= 10 else "0" + str(n)

def _share_color(pct):
    if pct < 15:
        return "#FF5252"
    elif pct < 30:
        return "#FFAB40"
    elif pct < 50:
        return "#C6FF00"
    return "#00E676"

def _co2_color(g):
    if g < 200:
        return "#00E676"
    elif g < 400:
        return "#C6FF00"
    elif g < 600:
        return "#FFAB40"
    return "#FF5252"

def _fetch_latest():
    # window starts on a full hour so the request body (and its cache key) changes only hourly
    now = time.now().in_location(TZ)
    start = now - time.parse_duration("2h")
    date_from = "%d-%s-%sT%s:00:00" % (start.year, _two(start.month), _two(start.day), _two(start.hour))
    date_to = now.format("2006-01-02") + "T23:59:59"

    res = http.post(
        CEPS_URL,
        body = SOAP_TEMPLATE % (date_from, date_to),
        headers = {
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPAction": "\"%s\"" % SOAP_ACTION,
        },
        ttl_seconds = CACHE_TTL,
    )
    if res.status_code != 200:
        return None

    doc = xpath.loads(res.body())
    stamp = doc.query("//item[last()]/@date")
    if not stamp:
        return None
    values = {}
    for src in SOURCES:
        raw = doc.query("//item[last()]/@" + src[0])
        values[src[0]] = max(float(raw), 0.0) if raw else 0.0
    return {"date": stamp, "values": values}

def _render_message(msg):
    return render.Root(
        child = render.Box(
            color = BG_COLOR,
            child = render.WrappedText(msg, font = "tom-thumb", color = LABEL_COLOR, align = "center"),
        ),
    )

def _stacked_bar(values, total, width, height):
    # cumulative rounding so the segments always sum to the full width
    segments = []
    acc = 0.0
    used = 0
    for src in SOURCES:
        acc += values[src[0]]
        end = int(math.round(acc / total * width))
        w = end - used
        if w > 0:
            segments.append(render.Box(width = w, height = height, color = src[2]))
            used = end
    return render.Row(children = segments)

def _leaf(scale, color):
    # tiny pixel leaf, 5x5 at 1x
    rows = ["..###", ".####", "#####", ".###.", "#...."]
    px = 1 * scale
    return render.Column(
        children = [
            render.Row(children = [render.Box(width = px, height = px, color = color if c == "#" else BG_COLOR) for c in row.elems()])
            for row in rows
        ],
    )

def main(config):
    scale = 2 if canvas.is2x() else 1
    width, height = canvas.size()
    small_font = "terminus-12" if scale == 2 else "tom-thumb"
    big_font = "terminus-24" if scale == 2 else "6x13"
    metric = config.str("metric", "res")

    data = _fetch_latest()
    if data == None:
        return _render_message("No ČEPS data")

    values = data["values"]
    total = 0.0
    green = 0.0
    co2_t = 0.0
    for src in SOURCES:
        v = values[src[0]]
        total += v
        if (metric == "lowcarbon" and src[4]) or (metric != "lowcarbon" and src[3]):
            green += v
        co2_t += v * src[5]
    if total <= 0:
        return _render_message("No ČEPS data")

    pct = int(math.round(green / total * 100))
    co2_g = int(math.round(co2_t / total * 1000))
    color = _share_color(pct)
    label = "LOW" if metric == "lowcarbon" else "OZE"

    # "2026-11-03T08:15:00+01:00" → "08:15"
    stamp = data["date"][11:16]

    header = render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Row(
                cross_align = "center",
                children = [
                    _leaf(scale, color),
                    render.Box(width = 2 * scale, height = 1),
                    render.Text(label, font = small_font, color = LABEL_COLOR),
                ],
            ),
            render.Text(stamp, font = small_font, color = LABEL_COLOR),
        ],
    )

    main_row = render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "end",
        children = [
            render.Text("%d%%" % pct, font = big_font, color = color),
            render.Column(
                cross_align = "end",
                children = [
                    render.Text("~%d" % co2_g, font = small_font, color = _co2_color(co2_g)),
                    render.Text("gCO2", font = small_font, color = LABEL_COLOR),
                ],
            ),
        ],
    )

    return render.Root(
        child = render.Box(
            width = width,
            height = height,
            color = BG_COLOR,
            child = render.Padding(
                pad = (1 * scale, 1 * scale, 1 * scale, 1 * scale),
                child = render.Column(
                    expanded = True,
                    main_align = "space_between",
                    children = [
                        header,
                        main_row,
                        _stacked_bar(values, total, width - 2 * scale, 5 * scale),
                    ],
                ),
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "metric",
                name = "Green metric",
                desc = "Renewables only (OZE) or all low-carbon sources including nuclear.",
                icon = "leaf",
                default = "res",
                options = [
                    schema.Option(display = "Renewables (OZE)", value = "res"),
                    schema.Option(display = "Low-carbon incl. nuclear", value = "lowcarbon"),
                ],
            ),
        ],
    )

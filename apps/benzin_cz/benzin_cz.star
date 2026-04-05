"""
Applet: Benzin CZ
Summary: Fuel prices from mbenzin.cz
Description: Displays current benzín and nafta prices for a Czech petrol station from mbenzin.cz.
Author: Tronbyt
"""

load("html.star", "html")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")

BASE_URL           = "https://www.mbenzin.cz/Ceny-benzinu-a-nafty/"
DEFAULT_PLACE      = "Mohelno-535"
DEFAULT_BRAND      = "EuroOil-silnice-392"
DEFAULT_STATION_ID = "16947"
CACHE_TTL          = 1800  # 30 minutes

# Foreground colours
COLOR_TITLE  = "#FFD700"  # gold  — station name
COLOR_BENZIN = "#00BFFF"  # cyan  — benzín
COLOR_NAFTA  = "#FF6347"  # tomato — nafta
COLOR_VALUE  = "#FFFFFF"  # white — price
COLOR_UNIT   = "#888888"  # grey  — "Kc"
COLOR_STALE  = "#555555"  # dark grey — N/A

# Background colours
BG_HEADER = "#1A1000"
BG_BENZIN = "#001822"
BG_NAFTA  = "#200800"

# Pulse frames: (benzin_accent, nafta_accent) — bright → dim → bright cycle
PULSE = [
    ("#00BFFF", "#FF6347"),
    ("#00A0D8", "#E05535"),
    ("#007799", "#BB3322"),
    ("#004466", "#771100"),
    ("#007799", "#BB3322"),
    ("#00A0D8", "#E05535"),
]

FRAME_DELAY = 120  # ms per frame

def fetch_prices(place, brand, station_id):
    """Fetch and parse benzín + nafta prices. Returns (benzin, nafta, station) or None."""
    res = http.get(
        BASE_URL + place + "/" + brand + "/" + station_id,
        ttl_seconds = CACHE_TTL,
        headers     = {"User-Agent": "Mozilla/5.0 (Pixlet)"},
    )

    if res.status_code != 200:
        return None

    doc = html(res.body())

    benzin  = doc.find("#ContentPlaceHolder1_lN95Cost").eq(0).text().strip()
    nafta   = doc.find("#ContentPlaceHolder1_lDieselCost").eq(0).text().strip()
    station = doc.find("h1").eq(0).text().strip()

    if benzin == "-" or benzin == "":
        benzin = "N/A"
    if nafta == "-" or nafta == "":
        nafta = "N/A"

    return benzin, nafta, station

def price_row(label, value, label_color, accent_color, bg_color, row_height):
    """A styled row with coloured background, left accent bar, and price on the right."""
    val_color = COLOR_VALUE if value != "N/A" else COLOR_STALE
    unit      = " Kc" if value != "N/A" else ""

    return render.Stack(
        children = [
            render.Box(width = 64, height = row_height, color = bg_color),
            render.Box(width = 3,  height = row_height, color = accent_color),
            render.Padding(
                pad  = (5, 2, 3, 0),
                child = render.Row(
                    expanded    = True,
                    main_align  = "space_between",
                    cross_align = "center",
                    children    = [
                        render.Text(content = label, color = label_color, font = "tb-8"),
                        render.Row(
                            children = [
                                render.Text(content = value, color = val_color, font = "tb-8"),
                                render.Text(content = unit,  color = COLOR_UNIT, font = "tb-8"),
                            ],
                        ),
                    ],
                ),
            ),
        ],
    )

def price_section(benzin, nafta, ba_accent, nf_accent):
    """One animation frame: both price rows with given accent colours."""
    return render.Column(
        children = [
            price_row("BA", benzin, COLOR_BENZIN, ba_accent, BG_BENZIN, 11),
            price_row("NF", nafta,  COLOR_NAFTA,  nf_accent, BG_NAFTA,  11),
        ],
    )

def main(config):
    place      = config.str("place",      DEFAULT_PLACE)
    brand      = config.str("brand",      DEFAULT_BRAND)
    station_id = config.str("station_id", DEFAULT_STATION_ID)
    result     = fetch_prices(place, brand, station_id)

    if result == None:
        return render.Root(
            child = render.WrappedText(
                content = "mbenzin.cz unavailable",
                color   = COLOR_STALE,
                width   = 64,
            ),
        )

    benzin, nafta, station = result

    # Build animated frames for the price rows
    frames = []
    for step in PULSE:
        frames.append(price_section(benzin, nafta, step[0], step[1]))

    return render.Root(
        delay = FRAME_DELAY,
        child = render.Column(
            children = [
                # Header: dark amber bg + scrolling gold station name
                render.Stack(
                    children = [
                        render.Box(width = 64, height = 9, color = BG_HEADER),
                        render.Padding(
                            pad  = (4, 1, 2, 0),
                            child = render.Marquee(
                                width = 58,
                                child = render.Text(
                                    content = station,
                                    color   = COLOR_TITLE,
                                    font    = "tb-8",
                                ),
                            ),
                        ),
                    ],
                ),
                # Gold divider line
                render.Box(width = 64, height = 1, color = COLOR_TITLE),
                # Animated price rows
                render.Animation(children = frames),
            ],
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields  = [
            schema.Text(
                id      = "place",
                name    = "Place",
                desc    = "Place slug from the mbenzin.cz URL (e.g. Mohelno-535).",
                icon    = "locationDot",
                default = DEFAULT_PLACE,
            ),
            schema.Text(
                id      = "brand",
                name    = "Brand / Station slug",
                desc    = "Station slug from the mbenzin.cz URL (e.g. EuroOil-silnice-392).",
                icon    = "gasPump",
                default = DEFAULT_BRAND,
            ),
            schema.Text(
                id      = "station_id",
                name    = "Station ID",
                desc    = "Numeric station ID from the mbenzin.cz URL (last segment, e.g. 16947).",
                icon    = "hashtag",
                default = DEFAULT_STATION_ID,
            ),
        ],
    )

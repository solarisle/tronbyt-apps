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

BASE_URL          = "https://www.mbenzin.cz/Ceny-benzinu-a-nafty/"
DEFAULT_PLACE     = "Mohelno-535"
DEFAULT_BRAND     = "EuroOil-silnice-392"
DEFAULT_STATION_ID = "16947"
CACHE_TTL        = 1800      # 30 minutes

COLOR_TITLE  = "#FFD700"  # gold  — station name
COLOR_BENZIN = "#00BFFF"  # cyan  — benzín label
COLOR_NAFTA  = "#FF6347"  # red   — nafta label
COLOR_VALUE  = "#FFFFFF"  # white — price number
COLOR_UNIT   = "#AAAAAA"  # grey  — "Kc" unit
COLOR_STALE  = "#888888"  # grey  — unknown price
COLOR_DIV    = "#333333"  # dark  — divider line

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
    if len(station) > 12:
        station = station[:12]

    return benzin, nafta, station

def price_row(label, value, label_color):
    """One row: label on the left, price + unit on the right."""
    val_color = COLOR_VALUE if value != "N/A" else COLOR_STALE
    unit      = " Kc" if value != "N/A" else ""

    return render.Row(
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

    return render.Root(
        child = render.Padding(
            pad   = (1, 1, 1, 1),
            child = render.Column(
                expanded   = True,
                main_align = "space_around",
                children   = [
                    render.Marquee(
                        width = 62,
                        child = render.Text(
                            content = station,
                            color   = COLOR_TITLE,
                            font    = "tb-8",
                        ),
                    ),
                    render.Box(width = 62, height = 1, color = COLOR_DIV),
                    price_row("BA", benzin, COLOR_BENZIN),
                    price_row("NF", nafta,  COLOR_NAFTA),
                ],
            ),
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

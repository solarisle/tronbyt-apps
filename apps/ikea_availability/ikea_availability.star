"""
Applet: IKEA Availability
Summary: Check IKEA item in-store availability
Description: Shows whether an IKEA item is available for cash & carry pickup at your chosen store.
Author: Tronbyt
"""

load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")

CIA_BASE  = "https://api.salesitem.ingka.com/availabilities"
CACHE_TTL = 3600   # 1 hour

COLOR_LABEL = "#FFDA1A"  # IKEA yellow
COLOR_OK    = "#00A651"  # green — in stock
COLOR_OOS   = "#E00751"  # red   — out of stock

def main(config):
    client_id  = config.get("client_id", "")
    item_no    = config.get("item_no", "")
    store_id   = config.get("store_id", "")
    item_label = config.get("item_label", "IKEA Item")

    if not client_id:
        return render_error("No client ID")

    if not item_no:
        return render_error("No item number")

    if not store_id:
        return render_error("No store ID")

    res = http.get(
        CIA_BASE + "/sto/" + store_id,
        params  = {"itemNos": item_no},
        headers = {"x-client-id": client_id, "Accept": "application/json"},
        ttl_seconds = CACHE_TTL,
    )

    if res.status_code != 200:
        return render_error("API error " + str(res.status_code))

    data   = res.json()
    avails = data.get("availabilities", [])

    if not avails:
        return render_error("No data")

    available    = avails[0].get("availableForCashCarry", False)
    status_text  = "IN STOCK" if available else "OUT OF STOCK"
    status_color = COLOR_OK   if available else COLOR_OOS

    return render.Root(
        child = render.Column(
            children = [
                render.Marquee(
                    width            = 64,
                    scroll_direction = "horizontal",
                    child = render.Text(
                        content = item_label,
                        color   = COLOR_LABEL,
                        font    = "6x13",
                    ),
                ),
                render.Box(width = 64, height = 4),
                render.Marquee(
                    width            = 64,
                    scroll_direction = "horizontal",
                    child = render.Text(
                        content = status_text,
                        color   = status_color,
                        font    = "6x13",
                    ),
                ),
            ],
        ),
    )

def render_error(msg):
    return render.Root(
        child = render.WrappedText(
            content = "ERROR: " + msg,
            color   = "#FF0000",
            width   = 64,
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id   = "client_id",
                name = "IKEA Client ID",
                desc = "Value of ciaApiClientKey found in the product page source (x-client-id header).",
                icon = "key",
            ),
            schema.Text(
                id   = "item_no",
                name = "Item Number",
                desc = "Item number from the IKEA product page URL (e.g. 40310208).",
                icon = "barcode",
            ),
            schema.Text(
                id   = "store_id",
                name = "Store ID",
                desc = "Numeric store ID from the product page source (storeState.shared.user.storeId).",
                icon = "store",
            ),
            schema.Text(
                id   = "item_label",
                name = "Item Label",
                desc = "Name to display on screen (e.g. IVAR bottle rack).",
                icon = "tag",
            ),
        ],
    )

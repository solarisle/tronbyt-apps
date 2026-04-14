"""
Applet: IKEA Availability
Summary: Check IKEA item in-store availability
Description: Shows whether an IKEA item is available for cash & carry pickup at your chosen store.
Author: Tronbyt
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")

CIA_BASE = "https://api.salesitem.ingka.com/availabilities"
CACHE_TTL = 3600  # 1 hour

COLOR_BG    = "#0058A3"  # IKEA blue — background
COLOR_LABEL = "#FFDA1A"  # IKEA yellow — item name
COLOR_OK    = "#FFFFFF"  # white — "In Stock:" label
COLOR_OOS   = "#FFDA1A"  # IKEA yellow — out of stock
COLOR_QTY   = "#FFDA1A"  # IKEA yellow — quantity number

def _hex2(n):
    s = "%X" % n
    return s if len(s) >= 2 else "0" + s

def make_gradient_spacer():
    yr, yg, yb = 255, 218, 26  # yellow #FFDA1A
    br, bg, bb = 0, 88, 163    # blue   #0058A3
    N = 20
    boxes = []
    for i in range(N):
        t = (1 - math.cos(2 * math.pi * i / N)) / 2
        r = int(yr + (br - yr) * t)
        g = int(yg + (bg - yg) * t)
        b = int(yb + (bb - yb) * t)
        boxes.append(render.Box(width = 64, height = 4, color = "#" + _hex2(r) + _hex2(g) + _hex2(b)))
    return render.Animation(children = boxes)

def main(config):
    client_id     = config.get("client_id", "")
    item_no       = config.get("item_no", "")
    store_id      = config.get("store_id", "")
    item_label    = config.get("item_label", "IKEA Item")
    alert_qty_str = config.get("alert_quantity", "")

    if not client_id:
        return render_error("No client ID")

    if not item_no:
        return render_error("No item number")

    if not store_id:
        return render_error("No store ID")

    res = http.get(
        CIA_BASE + "/sto/" + store_id,
        params = {"itemNos": item_no},
        headers = {"x-client-id": client_id, "Accept": "application/json"},
        ttl_seconds = CACHE_TTL,
    )

    if res.status_code != 200:
        return render_error("API error " + str(res.status_code))

    data = res.json()
    avails = data.get("availabilities", [])

    if not avails:
        return render_error("No data")

    available  = avails[0].get("availableForCashCarry", False)
    cash_carry = avails[0].get("buyingOption", {}).get("cashCarry", {})
    quantity   = int(cash_carry.get("availability", {}).get("quantity", 0))

    alert_qty = int(alert_qty_str) if alert_qty_str else 0
    is_alert  = available and alert_qty > 0 and quantity >= alert_qty

    if available:
        status_row = render.Row(
            children = [
                render.Text(content = "In Stock: ", color = COLOR_OK, font = "6x13"),
                render.Text(content = str(quantity), color = COLOR_QTY, font = "6x13"),
            ],
        )
    else:
        status_row = render.Text(
            content = "OUT OF STOCK",
            color = COLOR_OOS,
            font = "6x13",
        )

    # When alerting, replace the static spacer with a cosine-eased gradient bar.
    # Placing Animation only on the spacer keeps both Marquees as independent
    # siblings — they advance their scroll position every tick regardless.
    spacer = make_gradient_spacer() if is_alert else render.Box(width = 64, height = 4)

    return render.Root(
        child = render.Box(
            color = COLOR_BG,
            child = render.Column(
                children = [
                    render.Marquee(
                        width = 64,
                        scroll_direction = "horizontal",
                        child = render.Text(
                            content = item_label,
                            color = COLOR_LABEL,
                            font = "6x13",
                        ),
                    ),
                    spacer,
                    render.Marquee(
                        width = 64,
                        scroll_direction = "horizontal",
                        child = status_row,
                    ),
                ],
            ),
        ),
    )

def render_error(msg):
    return render.Root(
        child = render.Box(
            color = COLOR_BG,
            child = render.WrappedText(
                content = "ERROR: " + msg,
                color = "#FFDA1A",
                width = 64,
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "client_id",
                name = "IKEA Client ID",
                desc = "Value of ciaApiClientKey found in the product page source (x-client-id header).",
                icon = "key",
            ),
            schema.Text(
                id = "item_no",
                name = "Item Number",
                desc = "Item number from the IKEA product page URL (e.g. 40310208).",
                icon = "barcode",
            ),
            schema.Text(
                id = "store_id",
                name = "Store ID",
                desc = "Numeric store ID from the product page source (storeState.shared.user.storeId).",
                icon = "store",
            ),
            schema.Text(
                id = "item_label",
                name = "Item Label",
                desc = "Name to display on screen (e.g. IVAR bottle rack).",
                icon = "tag",
            ),
            schema.Text(
                id = "alert_quantity",
                name = "Alert Quantity",
                desc = "Flash an alert when stock reaches this number or more. Leave empty to disable.",
                icon = "bell",
            ),
        ],
    )

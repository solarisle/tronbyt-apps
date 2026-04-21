"""
Applet: ToyotaDashboard
Summary: Toyota vehicle status display
Description: Shows fuel level, driving range, odometer and door lock status using Toyota Connected Services (EU). Requires a refresh token obtained from the Toyota app OAuth2 login.
Author: ponbee
"""

load("cache.star", "cache")
load("encoding/base64.star", "base64")
load("encoding/json.star", "json")
load("hash.star", "hash")
load("hmac.star", "hmac")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

# ── Toyota EU API endpoints ───────────────────────────────────────────────────
TOKEN_URL = "https://b2c-login.toyota-europe.com/oauth2/realms/root/realms/tme/access_token"
VEHICLE_STATUS_URL = "https://ctpa-oneapi.tceu-ctp-prd.toyotaconnectedeurope.io/v1/global/remote/status"

# Fixed Toyota EU app constants (public, in the official mobile app)
API_KEY = "tTZipv6liF74PwMfk9Ed68AQ0bISswwf3iHQdqcF"
CLIENT_VERSION = "2.14.0"

# Basic auth = base64("oneapp:oneapp") — baked into the Toyota app
BASIC_AUTH = "Basic b25lYXBwOm9uZWFwcA=="

# ── Cache TTLs ────────────────────────────────────────────────────────────────
# access_token lives 3600 s; refresh 100 s early to avoid edge expiry.
# refresh_token is re-cached with 2× that window so it always outlasts the
# access_token entry — if access_token is gone, refresh_token is still there.
ACCESS_TOKEN_TTL = 3500
REFRESH_TOKEN_TTL = 7776000

# Vehicle data: 5-minute polling cap (Toyota rate-limit guidance)
VEHICLE_STATUS_TTL = 300

# ── Display colours ───────────────────────────────────────────────────────────
BG_COLOR = "#0A0A0A"
ACCENT_COLOR = "#CC0000"  # Toyota red
TEXT_COLOR = "#FFFFFF"
DIM_COLOR = "#888888"
FUEL_FILL_COLOR = "#CC0000"
FUEL_EMPTY_COLOR = "#2A2A2A"
LOCK_OK_COLOR = "#00CC44"
LOCK_WARN_COLOR = "#FF4444"

# ── Door sections we check for lock status ────────────────────────────────────
DOOR_SECTIONS = [
    "carstatus_item_driver_door",
    "carstatus_item_driver_rear_door",
    "carstatus_item_passenger_door",
    "carstatus_item_passenger_rear_door",
    "carstatus_item_rear_hatch",
]
DOOR_SHORT = {
    "carstatus_item_driver_door": "DrvDoor",
    "carstatus_item_driver_rear_door": "DrvRear",
    "carstatus_item_passenger_door": "PasDoor",
    "carstatus_item_passenger_rear_door": "PasRear",
    "carstatus_item_rear_hatch": "Hatch",
}

# ══════════════════════════════════════════════════════════════════════════════
#  JWT helpers
# ══════════════════════════════════════════════════════════════════════════════

def decode_jwt_payload(token):
    """Parse JWT payload without signature verification.

    Toyota tokens are RS256 JWTs.  We only need the claims (not verification),
    so we skip the signature and just base64url-decode the middle segment.

    Returns a dict, or {} on any parse failure.
    """
    parts = token.split(".")
    if len(parts) < 2:
        return {}

    payload_b64 = parts[1]

    # base64url → standard base64 (RFC 4648 §5 ↔ §4)
    payload_b64 = payload_b64.replace("-", "+").replace("_", "/")

    # Restore stripped padding ("=" characters)
    remainder = len(payload_b64) % 4
    if remainder == 2:
        payload_b64 = payload_b64 + "=="
    elif remainder == 3:
        payload_b64 = payload_b64 + "="

    decoded = base64.decode(payload_b64)
    if not decoded:
        return {}
    return json.decode(decoded)

# ══════════════════════════════════════════════════════════════════════════════
#  Token management  (access_token + refresh_token rotation)
# ══════════════════════════════════════════════════════════════════════════════

def _cache_prefix(refresh_token):
    """Stable 20-char cache key derived from the config refresh_token.

    Even after rotation the prefix is unchanged — it is based on the original
    token the user pasted in, which never changes.
    """
    return hash.sha256(refresh_token)[:20]

def _do_refresh(current_refresh_token, prefix):
    """POST to Toyota token endpoint and persist the rotated token pair.

    Returns new access_token string on success, None on failure.
    """
    resp = http.post(
        TOKEN_URL,
        headers = {"Authorization": BASIC_AUTH},
        form_body = {
            "grant_type": "refresh_token",
            "client_id": "oneapp",
            "redirect_uri": "com.toyota.oneapp:/oauth2Callback",
            "code_verifier": "plain",
            "refresh_token": current_refresh_token,
        },
        form_encoding = "application/x-www-form-urlencoded",
    )

    if resp.status_code != 200:
        return None

    data = resp.json()
    new_access = data.get("access_token", "")
    new_refresh = data.get("refresh_token", "")
    expires_in = int(data.get("expires_in", 3600))

    if not new_access or not new_refresh:
        return None

    at_ttl = min(expires_in - 60, ACCESS_TOKEN_TTL)
    cache.set("toyota_at_" + prefix, new_access, ttl_seconds = at_ttl)
    cache.set("toyota_rt_" + prefix, new_refresh, ttl_seconds = REFRESH_TOKEN_TTL)

    return new_access

def get_access_token(config_refresh_token):
    """Return a valid access_token, refreshing if the cached one has expired.

    Flow:
      1. Cache hit → return immediately (no HTTP).
      2. Cache miss → use latest refresh_token (from cache, or config on first
         run) to obtain a fresh access_token + rotated refresh_token.
    """
    prefix = _cache_prefix(config_refresh_token)
    current_rt = cache.get("toyota_rt_" + prefix)
    access_token = cache.get("toyota_at_" + prefix)
    print("RT_Token")
    print(current_rt)
    if access_token:
        return access_token
    print("No Access_token")

    #current_rt = cache.get("toyota_rt_" + prefix)
    if not current_rt:
        current_rt = config_refresh_token  # first ever render

    return _do_refresh(current_rt, prefix)

# ══════════════════════════════════════════════════════════════════════════════
#  Vehicle status API
# ══════════════════════════════════════════════════════════════════════════════

def _make_correlation_id(guid):
    """Pseudo-UUID for x-correlationid (hash-based, unique per request)."""
    h = hash.sha256(guid + str(time.now().unix) + str(time.now().nanosecond))
    return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]

def get_vehicle_status(access_token, guid, vin):
    """Fetch /v1/global/remote/status and cache the payload for 5 min.

    Returns the 'payload' dict from the Toyota response, or None on failure.
    """
    vs_key = "toyota_vs_" + hash.sha256(vin + guid)[:20]
    cached = cache.get(vs_key)
    if cached:
        return json.decode(cached)
    
    print("No cache from vs")

    # x-client-ref = HMAC-SHA256(CLIENT_VERSION, guid)  — as per Toyota app
    client_ref = hmac.sha256(CLIENT_VERSION, guid)
    correlation_id = _make_correlation_id(guid)

    headers = {
        "Authorization": "Bearer " + access_token,
        "x-api-key": API_KEY,
        "x-guid": guid,
        "guid": guid,
        "vin": vin,
        "x-brand": "T",
        "x-region": "EU",
        "x-channel": "ONEAPP",
        "x-appversion": CLIENT_VERSION,
        "x-client-ref": client_ref,
        "x-correlationid": correlation_id,
        "user-agent": "okhttp/4.10.0",
    }

    resp = http.get(VEHICLE_STATUS_URL, headers = headers)
    print("RESP:")
    print(resp.status_code)
    if resp.status_code != 200:
        return None

    data = resp.json()
    payload = data.get("payload", None)
    if not payload:
        return None

    cache.set(vs_key, json.encode(payload), ttl_seconds = VEHICLE_STATUS_TTL)
    return payload

# ══════════════════════════════════════════════════════════════════════════════
#  Data parsing
# ══════════════════════════════════════════════════════════════════════════════

def parse_telemetry(payload):
    """Extract fuel %, driving range and odometer from the payload.

    Returns (fuel_pct, range_km, odo_km) — each may be None if absent.
    """
    print (payload)
    tel = payload.get("telemetry", {})
    fuel_pct = tel.get("fugage", {}).get("value", None)
    range_km = tel.get("rage", {}).get("value", None)
    odo_km = tel.get("odo", {}).get("value", None)
    return (fuel_pct, range_km, odo_km)

def parse_lock_status(payload):
    """Inspect vehicleStatus and return (all_locked bool, list of open labels).

    Only door/hatch sections are considered for the lock check; windows are
    excluded because they report closed/open but rarely have a lock value.
    """
    vehicle_status = payload.get("vehicleStatus", [])
    all_locked = True
    open_parts = []

    for category in vehicle_status:
        for section in category.get("sections", []):
            name = section.get("section", "")
            if name not in DOOR_SECTIONS:
                continue
            for v in section.get("values", []):
                val = v.get("value", "")
                if val == "carstatus_unlocked":
                    all_locked = False
                    open_parts.append(DOOR_SHORT.get(name, name))

    return (all_locked, open_parts)

# ══════════════════════════════════════════════════════════════════════════════
#  Render helpers
# ══════════════════════════════════════════════════════════════════════════════

def _hex2(n):
    """Format integer 0-255 as two uppercase hex chars."""
    s = "%X" % n
    return s if len(s) >= 2 else "0" + s

def _make_accent_pulse(c1, c2, n = 8):
    """Cosine-eased colour pulse between c1 and c2 as (R, G, B) tuples.

    Returns a render.Animation of n frames, each a 3×15 Box.
    Placed as a sibling of Marquee widgets (never inside them) to avoid
    resetting their scroll position.
    """
    boxes = []
    for i in range(n):
        t = (1 - math.cos(2 * math.pi * i / n)) / 2
        r = int(c1[0] + (c2[0] - c1[0]) * t)
        g = int(c1[1] + (c2[1] - c1[1]) * t)
        b = int(c1[2] + (c2[2] - c1[2]) * t)
        boxes.append(render.Box(width = 3, height = 15, color = "#" + _hex2(r) + _hex2(g) + _hex2(b)))
    return render.Animation(children = boxes)

def _fuel_bar(pct, total_width = 43, height = 5):
    """Render a visual fuel bar as a Row of Boxes.

    Args:
        pct: fuel percentage 0-100 (float or int).
        total_width: total pixel width of the bar.
        height: pixel height of the bar.
    """
    filled_w = int(pct * total_width / 100.0)
    empty_w = total_width - filled_w
    children = []
    if filled_w > 0:
        children.append(render.Box(width = filled_w, height = height, color = FUEL_FILL_COLOR))
    if empty_w > 0:
        children.append(render.Box(width = empty_w, height = height, color = FUEL_EMPTY_COLOR))
    return render.Row(children = children)

def _data_row(label, value, value_color = TEXT_COLOR):
    """Single data row: dimmed label + value text, left-aligned."""
    print("Lable") 
    print(label)
    print("Value")
    print(value)
    return render.Row(
        cross_align = "center",
        children=[
                render.Text(content = label + " ", font = "tb-8", color = DIM_COLOR),
                render.Text(content = value , font = "tb-8", color = value_color),
        
        ],
    )

# ══════════════════════════════════════════════════════════════════════════════
#  Error / splash screen
# ══════════════════════════════════════════════════════════════════════════════

def _error_screen(title, msg):
    return render.Root(
        child = render.Stack(
            children = [
                render.Box(color = BG_COLOR),
                render.Column(
                    children = [
                        render.Box(
                            height = 13,
                            child = render.Row(
                                cross_align = "center",
                                children = [
                                    render.Box(width = 3, height = 13, color = ACCENT_COLOR),
                                    render.Box(width = 2, height = 13),
                                    render.Text(content = title, font = "tb-8", color = TEXT_COLOR),
                                ],
                            ),
                        ),
                        render.Box(height = 1, color = ACCENT_COLOR),
                        render.Box(
                            height = 18,
                            child = render.Row(
                                expanded = True,
                                main_align = "center",
                                cross_align = "center",
                                children = [
                                    render.WrappedText(
                                        content = msg,
                                        font = "tb-8",
                                        color = "#FFA500",
                                        width = 58,
                                    ),
                                ],
                            ),
                        ),
                    ],
                ),
            ],
        ),
    )

# ══════════════════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════════════════

def main(config):
    refresh_token = config.str("refresh_token", "")
    vin = config.str("vin", "")
    label = config.str("label", "")

    if not refresh_token or not vin:
        return _error_screen("Toyota", "Set token & VIN")

    # Header label: user-supplied name or first 8 chars of VIN
    display_label = label if label else vin[:8]

    # ── Auth ─────────────────────────────────────────────────────────────────
    access_token = get_access_token(refresh_token)
    if not access_token:
        return _error_screen("Toyota", "Auth failed. Re-login required.")

    print("Access_Token:")
    print(access_token)
    # guid = "sub" claim from the access_token JWT payload
    at_payload = decode_jwt_payload(access_token)
    guid = at_payload.get("sub", "")
    if not guid:
        return _error_screen("Toyota", "Cannot read token sub")

    # ── Vehicle data ─────────────────────────────────────────────────────────
    payload = get_vehicle_status(access_token, guid, vin)
    if not payload:
        return _error_screen("Toyota", "No vehicle data")

    (fuel_pct, range_km, odo_km) = parse_telemetry(payload)
    (all_locked, open_parts) = parse_lock_status(payload)

    # ── Build rows ───────────────────────────────────────────────────────────

    # Fuel row: percentage label (left, 21 px wide box) + visual bar (43 px)
    # Total: 21 + 43 = 64 px  ✓
    fuel_pct_safe = fuel_pct if fuel_pct != None else 0
    fuel_label = "%d%%" % int(fuel_pct_safe) if fuel_pct != None else "?%"
    fuel_row = render.Row(
        cross_align = "center",
        children = [
            render.Text(
                    content = fuel_label,
                    font = "tb-8",
                    color = TEXT_COLOR,
                ),
            
            _fuel_bar(fuel_pct_safe, total_width = 43, height = 8),
        ],
    )

    # Range row
    range_str = "%d km" % int(range_km) if range_km != None else "-- km"
    range_row = _data_row("Rng ", range_str)

    # Odometer row
    odo_str = "%d km" % int(odo_km) if odo_km != None else "-- km"
    odo_row = _data_row("ODO ", odo_str)

    # Lock row: green "Locked" or red list of open parts (horizontal Marquee
    # only on the text — not nested inside the vertical Marquee)
    if all_locked:
        lock_color = LOCK_OK_COLOR
        lock_text = "Locked"
    else:
        lock_color = LOCK_WARN_COLOR
        lock_text = "OPEN: " + ", ".join(open_parts)
    lock_row = _data_row("Lock", lock_text, value_color = lock_color)

    # Vertical Marquee scrolls 4 data rows (38 px total) through 18 px window.
    # At delay=80 ms → 1 px / tick → full scroll ~3 s, smooth reading pace.
    data_marquee = render.Marquee(
        height = 18,
        scroll_direction = "vertical",
        align = "center",
        child = render.Column(
            cross_align = "center",
            children = [
                fuel_row,
                render.Box(height = 2),
                range_row,
                render.Box(height = 2),
                odo_row,
                render.Box(height = 2),
                lock_row,
            ],
        ),
    )

    # Accent bar: normal pulse red↔dark; warning pulse red↔orange if unlocked
    if all_locked:
        accent = _make_accent_pulse((204, 0, 0), (80, 0, 0))
    else:
        accent = _make_accent_pulse((255, 80, 0), (180, 20, 0))

    return render.Root(
        delay = 80,  # ms — drives both pulse animation and scroll speed
        child = render.Stack(
            children = [
                render.Box(color = BG_COLOR),
                render.Column(
                    children = [
                        # ── Header (13 px) ────────────────────────────────
                        render.Box(
                            height = 13,
                            child = render.Row(
                                cross_align = "center",
                                children = [
                                    # Pulsing accent bar (Animation is a
                                    # SIBLING of Marquee, not inside it)
                                    accent,
                                    render.Box(width = 2, height = 13),
                                    render.Marquee(
                                        width = 59,
                                        child = render.Text(
                                            content = display_label,
                                            font = "6x13",
                                            color = TEXT_COLOR,
                                        ),
                                    ),
                                ],
                            ),
                        ),
                        # ── Divider (1 px) ────────────────────────────────
                        render.Box(height = 1, color = ACCENT_COLOR),
                        # ── Scrolling data (18 px) ────────────────────────
                        data_marquee,
                    ],
                ),
            ],
        ),
    )

# ══════════════════════════════════════════════════════════════════════════════
#  Schema
# ══════════════════════════════════════════════════════════════════════════════

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "refresh_token",
                name = "Toyota Refresh Token",
                desc = "Obtain from Toyota app OAuth2 login (see toyota_api_info.py). The app manages rotation automatically.",
                icon = "key",
                secret = True,
            ),
            schema.Text(
                id = "vin",
                name = "Vehicle VIN",
                desc = "Your 17-character vehicle identification number.",
                icon = "car",
            ),
            schema.Text(
                id = "label",
                name = "Display Label",
                desc = "Name shown in the header (e.g. 'Yaris Cross'). Defaults to first 8 chars of VIN.",
                icon = "tag",
                default = "",
            ),
        ],
    )

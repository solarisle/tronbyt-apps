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
VEHICLE_STATUS_URL = "https://ctpa-oneapi.tceu-ctp-prd.toyotaconnectedeurope.io/v1/vehicle/status"
TELEMETRY_URL = "https://ctpa-oneapi.tceu-ctp-prd.toyotaconnectedeurope.io/v3/telemetry"

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
BG_COLOR = "#0A1020"  # Dark navy (slightly brighter)
ACCENT_COLOR = "#00E5FF"  # Bright cyan
DIM_SEP_COLOR = "#1A3A55"  # Visible separator / empty segment
TEXT_COLOR = "#FFFFFF"  # Pure white for values
LABEL_COLOR = "#7AAFD4"  # Light steel blue for labels
FUEL_HIGH_COLOR = "#00FF88"  # Green  (>= 5/8 segments)
FUEL_MID_COLOR = "#FFD700"  # Gold   (3–4/8 segments)
FUEL_LOW_COLOR = "#FF4020"  # Red-orange (< 3/8 segments)
LOCK_OK_COLOR = "#00FF88"
LOCK_WARN_COLOR = "#FF3030"

# ── Door sections we check for lock status ────────────────────────────────────
DOOR_KEYS = ["driver", "passenger", "rearLeft", "rearRight", "rearBack"]
DOOR_SHORT = {
    "driver": "DrvDoor",
    "passenger": "PasDoor",
    "rearLeft": "RearL",
    "rearRight": "RearR",
    "rearBack": "Hatch",
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

    print("DEBUG new refresh_token (rotated):")
    print(new_refresh)

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

def _build_headers(access_token, guid, vin):
    """Common Toyota API headers, shared by /v1/vehicle/status and /v3/telemetry.

    x-client-ref = HMAC-SHA256(CLIENT_VERSION, guid) — as per Toyota app.
    """
    client_ref = hmac.sha256(CLIENT_VERSION, guid)
    correlation_id = _make_correlation_id(guid)

    return {
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

def get_vehicle_status(access_token, guid, vin):
    """Fetch /v1/vehicle/status and cache the 'payload' dict for 5 min.

    Returns the decoded 'payload' dict, or None on failure.
    """
    vs_key = "toyota_vs_" + hash.sha256(vin + guid)[:20]
    cached = cache.get(vs_key)
    if cached:
        return json.decode(cached)

    resp = http.get(VEHICLE_STATUS_URL, headers = _build_headers(access_token, guid, vin))
    print("vehicle/status RESP:")
    print(resp.status_code)
    if resp.status_code != 200:
        return None

    payload = resp.json().get("payload", None)
    if not payload:
        return None

    cache.set(vs_key, json.encode(payload), ttl_seconds = VEHICLE_STATUS_TTL)
    return payload

def get_telemetry(access_token, guid, vin):
    """Fetch /v3/telemetry and cache the 'payload' dict for 5 min.

    Returns the decoded 'payload' dict, or None on failure.
    """
    tel_key = "toyota_tel_" + hash.sha256(vin + guid)[:20]
    cached = cache.get(tel_key)
    if cached:
        return json.decode(cached)

    resp = http.get(TELEMETRY_URL, headers = _build_headers(access_token, guid, vin))
    print("telemetry RESP:")
    print(resp.status_code)
    if resp.status_code != 200:
        return None

    payload = resp.json().get("payload", None)
    if not payload:
        return None

    cache.set(tel_key, json.encode(payload), ttl_seconds = VEHICLE_STATUS_TTL)
    return payload

# ══════════════════════════════════════════════════════════════════════════════
#  Data parsing
# ══════════════════════════════════════════════════════════════════════════════

def parse_telemetry(payload):
    """Extract fuel %, driving range and odometer from the /v3/telemetry payload.

    Returns (fuel_pct, range_km, odo_km) — each may be None if absent.
    """
    fuel_pct = payload.get("fuelLevel", None)
    range_km = payload.get("distanceToEmpty", {}).get("value", None)
    odo_km = payload.get("odometer", {}).get("value", None)
    return (fuel_pct, range_km, odo_km)

def parse_lock_status(payload):
    """Inspect doors and return (all_locked bool, list of open labels).

    Only door sections are considered for the lock check (hood has no
    lockStatus, windows aren't part of this payload's doors dict).
    """
    doors = payload.get("doors", {})
    all_locked = True
    open_parts = []

    for key in DOOR_KEYS:
        status = doors.get(key, {}).get("lockStatus", {}).get("status", "")
        if status == "unlocked":
            all_locked = False
            open_parts.append(DOOR_SHORT.get(key, key))

    return (all_locked, open_parts)

# ══════════════════════════════════════════════════════════════════════════════
#  Render helpers
# ══════════════════════════════════════════════════════════════════════════════

def _hex2(n):
    """Format integer 0-255 as two uppercase hex chars."""
    s = "%X" % n
    return s if len(s) >= 2 else "0" + s

def _make_accent_breath(c1, c2, n = 20):
    """Slow cosine-eased breathing between c1 and c2 as (R, G, B) tuples.

    n=20 frames × 80ms delay = 1600ms cycle — noticeably slower than a fast pulse.
    Returns a render.Animation of n frames, each a 6px Circle.
    Must be placed as a sibling of any Marquee (never inside one).
    """
    circles = []
    for i in range(n):
        t = (1 - math.cos(2 * math.pi * i / n)) / 2
        r = int(c1[0] + (c2[0] - c1[0]) * t)
        g = int(c1[1] + (c2[1] - c1[1]) * t)
        b = int(c1[2] + (c2[2] - c1[2]) * t)
        circles.append(render.Circle(diameter = 6, color = "#" + _hex2(r) + _hex2(g) + _hex2(b)))
    return render.Animation(children = circles)

def _make_accent_flash(color_on, n_on = 4, n_off = 5):
    """Hard on/off flash animation.

    n_on frames bright then n_off frames dark → clear warning strobe.
    At 80ms delay: 4+5=9 frames = 720ms cycle, on for 320ms, off for 400ms.
    Returns a render.Animation of (n_on + n_off) frames, each a 6px Circle.
    Must be placed as a sibling of any Marquee (never inside one).
    """
    frames = []
    for _ in range(n_on):
        frames.append(render.Circle(diameter = 6, color = color_on))
    for _ in range(n_off):
        frames.append(render.Circle(diameter = 6, color = BG_COLOR))
    return render.Animation(children = frames)

def _fuel_segments(pct):
    """Render 8 segmented fuel blocks (47px wide).

    Segment colour depends on fill level:
      >= 5/8  → green (high)
      >= 3/8  → gold  (mid)
      <  3/8  → red   (low)
    Empty segments use the dark separator colour.
    """
    num_filled = int(pct * 8 / 100)
    if num_filled >= 5:
        fill_color = FUEL_HIGH_COLOR
    elif num_filled >= 3:
        fill_color = FUEL_MID_COLOR
    else:
        fill_color = FUEL_LOW_COLOR
    children = []
    for i in range(8):
        seg_color = fill_color if i < num_filled else DIM_SEP_COLOR
        children.append(render.Box(width = 4, height = 8, color = seg_color))
        if i < 7:
            children.append(render.Box(width = 1, height = 8, color = BG_COLOR))
    return render.Row(children = children)
    # Width: 8×4 + 7×1 = 39px

def _hud_row(label, value_text, value_color = TEXT_COLOR):
    """Single HUD data row: steel-blue 3-char label + value, 8px tall."""
    return render.Box(
        height = 8,
        child = render.Row(
            cross_align = "center",
            children = [
                render.Box(width = 2, height = 8),
                render.Text(content = label, font = "tom-thumb", color = LABEL_COLOR),
                render.Box(width = 3, height = 8),
                render.Text(content = value_text, font = "tb-8", color = value_color),
            ],
        ),
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
                            height = 9,
                            child = render.Row(
                                cross_align = "center",
                                children = [
                                    render.Box(width = 2, height = 9, color = ACCENT_COLOR),
                                    render.Box(width = 2, height = 9),
                                    render.Text(content = title, font = "tb-8", color = ACCENT_COLOR),
                                ],
                            ),
                        ),
                        render.Box(height = 1, color = ACCENT_COLOR),
                        render.Box(
                            height = 22,
                            child = render.Row(
                                expanded = True,
                                main_align = "center",
                                cross_align = "center",
                                children = [
                                    render.WrappedText(
                                        content = msg,
                                        font = "tb-8",
                                        color = "#FFA500",
                                        width = 60,
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
    display_refresh_token = config.bool("display_refresh_token")

    if not refresh_token or not vin:
        return _error_screen("Toyota", "Set token & VIN")

    # Header label: user-supplied name or first 8 chars of VIN
    display_label = label if label else vin[:8]

    # ── Debug: print cached refresh token ────────────────────────────────────
    if display_refresh_token:
        prefix = _cache_prefix(refresh_token)
        cached_rt = cache.get("toyota_rt_" + prefix)
        print("DEBUG cached refresh_token: " + (cached_rt if cached_rt else "(none)"))

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
    vs_payload = get_vehicle_status(access_token, guid, vin)
    if not vs_payload:
        return _error_screen("Toyota", "No vehicle data")

    tel_payload = get_telemetry(access_token, guid, vin)

    (fuel_pct, range_km, odo_km) = parse_telemetry(tel_payload) if tel_payload else (None, None, None)
    (all_locked, open_parts) = parse_lock_status(vs_payload)

    # ── Build data values ─────────────────────────────────────────────────────

    fuel_pct_safe = fuel_pct if fuel_pct != None else 0
    fuel_label = "%d%%" % int(fuel_pct_safe) if fuel_pct != None else "?%"

    range_str = "%d km" % int(range_km) if range_km != None else "-- km"
    odo_str = "%d km" % int(odo_km) if odo_km != None else "-- km"

    # Lock status
    if all_locked:
        lock_widget = render.Text(content = "Zamčeno", font = "tb-8", color = LOCK_OK_COLOR)
    else:
        lock_widget = render.Marquee(
            width = 50,
            child = render.Text(
                content = "Otevřeno: " + "  ".join(open_parts),
                font = "tb-8",
                color = LOCK_WARN_COLOR,
            ),
        )

    # ── Zone A — Header (8px) ─────────────────────────────────────────────────
    # Layout: [6px accent circle anim] [1px] [57px label marquee]
    # Total:  6 + 1 + 57 = 64 ✓
    #
    # Left circle = lock indicator:
    #   locked   → slow cyan breathing (_make_accent_breath)
    #   unlocked → hard red flash     (_make_accent_flash)
    #
    # accent_animation is a SIBLING of the Marquee inside the Row — required
    # pattern to prevent Animation from resetting Marquee scroll position.
    if all_locked:
        accent = _make_accent_breath((0, 200, 255), (0, 30, 50))
    else:
        accent = _make_accent_flash(LOCK_WARN_COLOR)

    zone_a = render.Box(
        height = 8,
        child = render.Row(
            cross_align = "center",
            children = [
                accent,
                render.Box(width = 1, height = 8),
                render.Marquee(
                    width = 57,
                    child = render.Text(
                        content = display_label,
                        font = "tb-8",
                        color = ACCENT_COLOR,
                    ),
                ),
            ],
        ),
    )

    # ── Zone B1 — Cyan divider (1px) ──────────────────────────────────────────
    zone_b1 = render.Box(height = 1, color = ACCENT_COLOR)

    # ── Zone B2 — Fuel segments (10px) ────────────────────────────────────────
    # Layout: [1px] [20px label box] [1px] [39px segments] [3px pad]
    # Total:  1 + 20 + 1 + 39 + 3 = 64 ✓
    zone_b2 = render.Box(
        height = 10,
        child = render.Column(
            children = [
                render.Box(height = 1),
                render.Row(
                    cross_align = "center",
                    children = [
                        render.Box(width = 1, height = 8),
                        render.Box(
                            width = 20,
                            height = 8,
                            child = render.Text(
                                content = fuel_label,
                                font = "tb-8",
                                color = LABEL_COLOR,
                            ),
                        ),
                        render.Box(width = 1, height = 8),
                        _fuel_segments(fuel_pct_safe),
                        render.Box(width = 3, height = 8),
                    ],
                ),
                render.Box(height = 1),
            ],
        ),
    )

    # ── Zone B3 — Dark separator (1px) ────────────────────────────────────────
    zone_b3 = render.Box(height = 1, color = DIM_SEP_COLOR)

    # ── Zone D — Scrolling data (12px window) ────────────────────────────────
    # Inner content: 3 rows × 8px + 2 spacers × 2px = 28px → scrolls in 12px.
    zone_d = render.Marquee(
        height = 12,
        scroll_direction = "vertical",
        align = "center",
        child = render.Column(
            cross_align = "start",
            children = [
                _hud_row("Dojezd", range_str),
                render.Box(height = 2),
                _hud_row("Odometr", odo_str),
                render.Box(height = 2),
                render.Box(
                    height = 8,
                    child = render.Row(
                        cross_align = "center",
                        children = [
                            render.Box(width = 2, height = 8),
                            render.Text(content = "Zámek", font = "tom-thumb", color = LABEL_COLOR),
                            render.Box(width = 3, height = 8),
                            lock_widget,
                        ],
                    ),
                ),
            ],
        ),
    )

    return render.Root(
        delay = 80,
        child = render.Stack(
            children = [
                render.Box(color = BG_COLOR),
                render.Column(
                    children = [
                        zone_a,  # 8px
                        zone_b1,  # 1px
                        zone_b2,  # 10px
                        zone_b3,  # 1px
                        zone_d,  # 12px
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
            schema.Toggle(
                id = "display_refresh_token",
                name = "Debug: Print Refresh Token",
                desc = "When enabled, prints the cached refresh token to the log for debugging token rotation.",
                icon = "bug",
                default = False,
            ),
        ],
    )

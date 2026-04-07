"""
Applet: TuyaDevice
Summary: Display Tuya device temperature
Description: Shows temperature readings from Tuya-compatible smart devices. Requires Tuya Access ID and Secret.
Author: ponbee
"""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("hash.star", "hash")
load("hmac.star", "hmac")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
TOKEN_TTL = 6000
DEVICE_TTL = 300

# Known Tuya DP codes that carry temperature values
TEMP_CODES = ["temp_current", "va_temperature", "temp", "temperature", "cur_temperature"]
HUMIDITY_CODES = ["va_humidity", "humidity", "cur_humidity", "humid"]

SIG_HEADERS_VALUE = "client_id:t:nonce"

def generate_signature(method, url_path, query, timestamp, client_id, access_token, secret, nonce):
    # Headers in string_to_sign must be only those listed in Signature-Headers
    headers_part = (
        "client_id:" + client_id + "\n" +
        "t:" + timestamp + "\n" +
        "nonce:" + nonce + "\n"
    )

    url_with_query = url_path + "?" + query if query else url_path
    string_to_sign = method + "\n" + EMPTY_SHA256 + "\n" + headers_part + "\n" + url_with_query

    if access_token:
        message = client_id + access_token + timestamp + nonce + string_to_sign
    else:
        message = client_id + timestamp + nonce + string_to_sign
    
    return hmac.sha256(secret, message).upper()

def make_signed_request(method, url_path, client_id, secret, query = "", access_token = "", endpoint = "https://openapi.tuyaus.com"):
    now = time.now()
    timestamp = str(now.unix * 1000)
    nonce = str(now.unix) + str(now.nanosecond)

    sign = generate_signature(method, url_path, query, timestamp, client_id, access_token, secret, nonce)

    headers = {
        "client_id": client_id,
        "t": timestamp,
        "sign": sign,
        "sign_method": "HMAC-SHA256",
        "Signature-Headers": SIG_HEADERS_VALUE,
        "nonce": nonce,
    }
    if access_token:
        headers["access_token"] = access_token

    url = endpoint + url_path
    if query:
        url = url + "?" + query

    return http.get(url, headers = headers)

def get_token(client_id, secret, endpoint):
    cache_key = "tuya_token_" + hash.sha256(client_id + secret + endpoint)
    cached = cache.get(cache_key)
    if cached:
        return cached

    resp = make_signed_request("GET", "/v1.0/token", client_id, secret, query = "grant_type=1", endpoint = endpoint)
    if resp.status_code != 200:
        return None

    data = resp.json()
    if not data.get("success", False):
        return None

    result = data.get("result", {})
    token = result.get("access_token", None)
    if token:
        cache.set(cache_key, token, ttl_seconds = TOKEN_TTL)
    return token

def get_device_info(device_id, access_token, client_id, secret, endpoint):
    url_path = "/v1.0/devices/" + device_id
    cache_key = "tuya_device_" + hash.sha256(client_id + device_id)
    cached = cache.get(cache_key)
    if cached:
        return json.decode(cached)

    resp = make_signed_request("GET", url_path, client_id, secret, access_token = access_token, endpoint = endpoint)
    if resp.status_code != 200:
        return None

    data = resp.json()
    if not data.get("success", False):
        return None

    cache.set(cache_key, json.encode(data), ttl_seconds = DEVICE_TTL)
    return data

def get_temp_celsius(device_data):
    result = device_data.get("result", {})
    for status in result.get("status", []):
        if status.get("code", "") in TEMP_CODES:
            val = status.get("value", None)
            if val == None:
                return None
            temp = float(val) / 10.0
            return temp
    return None

def get_humidity(device_data):
    result = device_data.get("result", {})
    for status in result.get("status", []):
        if status.get("code", "") in HUMIDITY_CODES:
            val = status.get("value", None)
            if val == None:
                return None
            h = float(val)
            if h > 100:
                h = h / 10.0
            return h
    return None

def format_temperature(celsius, unit):
    if celsius == None:
        return "N/A"
    if unit == "Fahrenheit":
        f = celsius * 9.0 / 5.0 + 32.0
        return "%s°F" % math_round(f)
    return "%s°C" % math_round(celsius)

def temp_color(celsius):
    if celsius == None:
        return "#AAAAAA"
    if celsius < 10:
        return "#4FC3F7"  # ice blue
    elif celsius < 18:
        return "#81D4FA"  # cool blue
    elif celsius < 26:
        return "#69F0AE"  # comfortable green
    elif celsius < 32:
        return "#FFAB40"  # warm amber
    else:
        return "#FF5252"  # hot red

def math_round(val):
    factor = 10
    rounded = int(val * factor + 0.5) if val >= 0 else -int(-val * factor + 0.5)
    whole = rounded // factor
    frac = abs(rounded) % factor
    return "%d.%d" % (whole, frac)

def error_screen(line1, line2):
    return render.Root(
        child = render.Stack(
            children = [
                render.Box(color = "#0D1B2A"),
                render.Column(
                    children = [
                        render.Box(
                            height = 12,
                            child = render.Row(
                                cross_align = "center",
                                children = [
                                    render.Box(width = 3, height = 12, color = "#FF3C00"),
                                    render.Box(width = 2, height = 12),
                                    render.Text(content = line1, font = "tb-8", color = "#FF5252"),
                                ],
                            ),
                        ),
                        render.Box(height = 1, color = "#FF3C00"),
                        render.Box(
                            height = 19,
                            child = render.Row(
                                expanded = True,
                                main_align = "center",
                                cross_align = "center",
                                children = [
                                    render.WrappedText(content = line2, font = "tb-8", color = "#FFA500", width = 58),
                                ],
                            ),
                        ),
                    ],
                ),
            ],
        ),
    )

def main(config):
    client_id = config.str("access_id", "")
    secret = config.str("access_secret", "")
    device_id = config.str("device_id", "")
    endpoint = config.str("endpoint", "https://openapi.tuyaus.com")
    unit = config.str("temperature_unit", "Celsius")

    if not client_id or not secret or not device_id:
        return render.Root(
            child = render.Stack(
                children = [
                    render.Box(color = "#0D1B2A"),
                    render.Column(
                        children = [
                            render.Box(
                                height = 12,
                                child = render.Row(
                                    cross_align = "center",
                                    children = [
                                        render.Box(width = 3, height = 12, color = "#FF6B35"),
                                        render.Box(width = 2, height = 12),
                                        render.Text(content = "Tuya Device", font = "tb-8", color = "#FFFFFF"),
                                    ],
                                ),
                            ),
                            render.Box(height = 1, color = "#FF6B35"),
                            render.Box(
                                height = 19,
                                child = render.Row(
                                    expanded = True,
                                    main_align = "center",
                                    cross_align = "center",
                                    children = [
                                        render.WrappedText(content = "Set ID, Secret & Device ID", font = "tb-8", color = "#888888", width = 58),
                                    ],
                                ),
                            ),
                        ],
                    ),
                ],
            ),
        )

    token = get_token(client_id, secret, endpoint)
    if not token:
        return error_screen("Tuya Error", "Auth failed")

    device_data = get_device_info(device_id, token, client_id, secret, endpoint)
    if not device_data:
        return error_screen("Tuya Error", "Device not found")
    
    result = device_data.get("result", {})
    device_name = result.get("name", "Tuya Device")
    celsius = get_temp_celsius(device_data)
    temperature = format_temperature(celsius, unit)
    t_color = temp_color(celsius)
    humidity = get_humidity(device_data)
    humidity_str = "%d%%" % int(humidity) if humidity != None else None

    # Accent bar pulses through orange shades for a "breathing" glow effect
    accent_bar = render.Animation(
        children = [
            render.Box(width = 3, height = 15, color = "#FF6B35"),
            render.Box(width = 3, height = 15, color = "#FF8C00"),
            render.Box(width = 3, height = 15, color = "#FFD700"),
            render.Box(width = 3, height = 15, color = "#FF8C00"),
            render.Box(width = 3, height = 15, color = "#FF6B35"),
            render.Box(width = 3, height = 15, color = "#CC4400"),
            render.Box(width = 3, height = 15, color = "#FF3300"),
            render.Box(width = 3, height = 15, color = "#CC4400"),
        ],
    )

    return render.Root(
        delay = 120,
        child = render.Stack(
            children = [
                render.Box(color = "#0D1B2A"),
                render.Column(
                    children = [
                        # Header: pulsing accent bar + scrolling device name
                        render.Box(
                            height = 15,
                            child = render.Row(
                                cross_align = "center",
                                children = [
                                    accent_bar,
                                    render.Box(width = 2, height = 15),
                                    render.Marquee(
                                        width = 59,
                                        child = render.Text(
                                            content = device_name,
                                            font = "6x13",
                                            color = "#FFFFFF",
                                        ),
                                    ),
                                ],
                            ),
                        ),
                        # Divider
                        render.Box(height = 1, color = "#FF6B35"),
                        # Temperature + Humidity
                        render.Box(
                            height = 16,
                            child = render.Row(
                                expanded = True,
                                main_align = "center",
                                cross_align = "center",
                                children = [
                                    render.Text(
                                        content = temperature,
                                        font = "6x13",
                                        color = t_color,
                                    ),
                                ] + ([
                                    render.Box(width = 4, height = 16),
                                    render.Text(
                                        content = humidity_str,
                                        font = "6x13",
                                        color = "#64B5F6",
                                    ),
                                ] if humidity_str else []),
                            ),
                        ),
                    ],
                ),
            ],
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "access_id",
                name = "Tuya Access ID",
                desc = "Your Tuya Cloud Access ID (Client ID)",
                icon = "key",
                secret = True,
            ),
            schema.Text(
                id = "access_secret",
                name = "Tuya Access Secret",
                desc = "Your Tuya Cloud Access Secret",
                icon = "lock",
                secret = True,
            ),
            schema.Text(
                id = "device_id",
                name = "Device ID",
                desc = "The Tuya device ID to monitor",
                icon = "microchip",
            ),
            schema.Dropdown(
                id = "endpoint",
                name = "Region",
                desc = "Tuya Cloud API region",
                icon = "globe",
                default = "https://openapi.tuyaus.com",
                options = [
                    schema.Option(display = "China", value = "https://openapi.tuyacn.com"),
                    schema.Option(display = "US West", value = "https://openapi.tuyaus.com"),
                    schema.Option(display = "US East", value = "https://openapi-ueaz.tuyaus.com"),
                    schema.Option(display = "EU Central", value = "https://openapi.tuyaeu.com"),
                    schema.Option(display = "EU West", value = "https://openapi-weaz.tuyaeu.com"),
                    schema.Option(display = "India", value = "https://openapi.tuyain.com"),
                    schema.Option(display = "Singapore", value = "https://openapi-sg.iotbing.com"),
                ],
            ),
            schema.Dropdown(
                id = "temperature_unit",
                name = "Temperature Unit",
                desc = "Display temperature in Celsius or Fahrenheit",
                icon = "thermometer",
                default = "Celsius",
                options = [
                    schema.Option(display = "Celsius", value = "Celsius"),
                    schema.Option(display = "Fahrenheit", value = "Fahrenheit"),
                ],
            ),
        ],
    )

"""
Applet: Google Review
Summary: Display Google Maps reviews
Description: Shows the latest Google Maps review with rating, date, reviewer name, and snippet.
Author: Tronbyt
"""

load("http.star", "http")
load("random.star", "random")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")
load("images/star_filled.webp", STAR_FILLED_ASSET = "file")
load("images/star_empty.webp", STAR_EMPTY_ASSET = "file")

CACHE_TIMEOUT = 43200  # 12 hours
MAX_CHARS_PER_LINE = 12  # approximate chars that fit in 64px width
MAX_CHARS_PER_LINE_WIDE = 10  # ~10 chars fit in 64px with 6x13 font (6px/char)
DEFAULT_TEXT_SPEED = "100"

ISO_DATE_FORMAT = "2006-01-02T15:04:05Z"  # serpapi iso_date, e.g. "2026-07-17T18:00:57Z"

# Load star icons
STAR_FILLED = STAR_FILLED_ASSET.readall()
STAR_EMPTY = STAR_EMPTY_ASSET.readall()

# Modern color palette
COLOR_HEADER = "#E8F5E9"        # Light mint green
COLOR_RATING = "#FFC107"        # Modern amber/gold
COLOR_DATE = "#81D4FA"          # Modern light cyan
COLOR_USER = "#FFB74D"          # Warm orange
COLOR_SNIPPET = "#CE93D8"       # Modern purple

NEWS_FLASH_TEXT = "!NEWS!"
FLASH_BG_COLORS = ["#FF1744", "#FFD700"]  # red / gold alternating
FLASH_TEXT_COLORS = ["#FFFFFF", "#000000"]  # matching contrast per bg
FLASH_DURATION_MS = 2000

def build_star_row(rating_int):
    """Build a row of star icons based on rating"""
    stars = []

    # Add filled stars (yellow gradient)
    for i in range(rating_int):
        stars.append(
            render.Image(src = STAR_FILLED, width = 10, height = 10)
        )

    # Add empty stars (outlined)
    for i in range(5 - rating_int):
        stars.append(
            render.Image(src = STAR_EMPTY, width = 10, height = 10)
        )

    # Add rating number
    stars.append(
        render.Text(
            content = " " + str(rating_int) + "/5",
            color = COLOR_RATING,
            font = "CG-pixel-3x5-mono",
        )
    )

    return stars

def _is_today(iso_date_str, now):
    """Return True if iso_date_str (RFC3339 UTC) is on the same calendar day as now."""
    if not iso_date_str:
        return False
    if len(iso_date_str) != 20 or not iso_date_str.endswith("Z"):
        return False
    review_time = time.parse_time(iso_date_str, ISO_DATE_FORMAT, time.tz())
    return (review_time.year == now.year and
            review_time.month == now.month and
            review_time.day == now.day)

def _make_news_flash(frame_count):
    """Full-screen alternating-background "!NEWS!" flash, ~2s total.
    A Sequence sibling of review_marquee - never nests Marquee inside
    this Animation, avoiding the Animation/Marquee scroll-reset gotcha."""
    frames = []
    for i in range(frame_count):
        idx = i % 2
        frames.append(
            render.Box(
                width = 64,
                height = 32,
                color = FLASH_BG_COLORS[idx],
                child = render.Text(content = NEWS_FLASH_TEXT, font = "10x20", color = FLASH_TEXT_COLORS[idx]),
            ),
        )
    return render.Animation(children = frames)

def word_wrap(text, max_chars):
    """Wrap text at word boundaries to prevent mid-word breaks."""
    words = text.split(" ")
    lines = []
    current_line = ""

    for word in words:
        if len(word) > max_chars:
            if current_line:
                lines.append(current_line)
                current_line = ""
            chunks = len(word) // max_chars + (1 if len(word) % max_chars else 0)
            for i in range(chunks):
                chunk = word[i * max_chars:(i + 1) * max_chars]
                if i == chunks - 1:
                    current_line = chunk
                else:
                    lines.append(chunk)
        elif current_line == "":
            current_line = word
        elif len(current_line) + 1 + len(word) <= max_chars:
            current_line = current_line + " " + word
        else:
            lines.append(current_line)
            current_line = word

    if current_line:
        lines.append(current_line)

    return "\n".join(lines)

def main(config):
    # Get API key and data_id from config
    api_key = config.get("api_key", "")
    data_id = config.get("data_id", "")
    hl = config.get("language", "en")

    if not api_key:
        return render_error("No API key provided")

    if not data_id:
        return render_error("No data_id provided")

    # Build API URL with provided API key, data_id, and language preference
    api_url = "https://serpapi.com/search.json?engine=google_maps_reviews&data_id=" + data_id + "&sort_by=newestFirst&hl=" + hl + "&api_key=" + api_key

    # Fetch data from API
    response = http.get(api_url, ttl_seconds = CACHE_TIMEOUT)

    if response.status_code != 200:
        error_data = response.json()
        error_msg = error_data.get("error", "API Error: " + str(response.status_code))
        return render_error(error_msg)

    data = response.json()

    # Get place name from response
    place_info = data.get("place_info", {})
    place_name = place_info.get("title", "GOOGLE REVIEW")

    # Get reviews and pick a random one (up to first 5)
    reviews = data.get("reviews", [])
    if not reviews:
        return render_error("No reviews found")

    review_count = min(len(reviews), 5)
    candidates = reviews[:review_count]

    now = time.now().in_location(time.tz())
    today_candidates = [r for r in candidates if _is_today(r.get("iso_date", ""), now)]

    if today_candidates:
        review = today_candidates[random.number(0, len(today_candidates) - 1)]
        is_today_review = True
    else:
        review = candidates[random.number(0, review_count - 1)]
        is_today_review = False

    rating = review.get("rating")
    date = review.get("date", "Unknown")
    user_name = review.get("user", {}).get("name", "Anonymous")
    snippet = review.get("snippet", "No comment provided")

    # Format rating display
    rating_int = 0
    if rating:
        rating_int = int(rating)

    text_delay = int(config.str("text_speed", DEFAULT_TEXT_SPEED))

    review_marquee = render.Marquee(
        width = 64,
        height = 32,
        scroll_direction = "vertical",
        align = "center",
        child = render.Column(
            cross_align = "center",
            children = [
                # Header
                render.WrappedText(
                    content = word_wrap(place_name, MAX_CHARS_PER_LINE_WIDE),
                    color = COLOR_HEADER,
                    #font = "6x13",
                    width = 64,
                ),
                render.Box(width = 64, height = 4),

                # Rating with multiple stars
                render.Row(
                    main_align = "center",
                    cross_align = "center",
                    children = build_star_row(rating_int if rating else 0),
                ),
                render.Box(width = 64, height = 4),

                # Date
                render.WrappedText(
                    content = word_wrap("Date: " + date, MAX_CHARS_PER_LINE_WIDE),
                    color = COLOR_DATE,
                    #font = "6x13",
                    width = 64,
                ),
                render.Box(width = 64, height = 4),

                # User Name
                render.WrappedText(
                    content = word_wrap("By: " + user_name, MAX_CHARS_PER_LINE_WIDE),
                    color = COLOR_USER,
                    #font = "6x13",
                    width = 64,
                ),
                render.Box(width = 64, height = 4),

                # Snippet
                render.WrappedText(
                    content = word_wrap(snippet, MAX_CHARS_PER_LINE),
                    color = COLOR_SNIPPET,
                    width = 64,
                ),
            ],
        ),
    )

    if is_today_review:
        flash_frame_count = max(2, FLASH_DURATION_MS // text_delay)
        root_child = render.Sequence(
            children = [_make_news_flash(flash_frame_count), review_marquee],
        )
    else:
        root_child = review_marquee

    return render.Root(
        delay = text_delay,
        child = root_child,
    )

def render_error(error_text):
    """Render error message"""
    return render.Root(
        child = render.WrappedText(
            content = "ERROR: " + error_text,
            color = "#ff0000",
            width = 64,
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "api_key",
                name = "SerpAPI Key",
                desc = "Your SerpAPI key (get from serpapi.com/manage-api-key)",
                icon = "key",
            ),
            schema.Text(
                id = "data_id",
                name = "Google Maps Place ID",
                desc = "Google Maps data_id from SerpAPI search results",
                icon = "mapPin",
            ),
            schema.Text(
                id = "language",
                name = "Language",
                desc = "Language code for reviews (e.g. en, ja, fr). Defaults to en.",
                icon = "language",
            ),
            schema.Dropdown(
                id = "text_speed",
                name = "Display Speed",
                desc = "The speed for scrolling the content.",
                icon = "personRunning",
                default = "100",
                options = [
                    schema.Option(
                        display = "Fast",
                        value = "50",
                    ),
                    schema.Option(
                        display = "Normal",
                        value = "100",
                    ),
                    schema.Option(
                        display = "Slow",
                        value = "150",
                    ),
                ],
            ),
        ],
    )

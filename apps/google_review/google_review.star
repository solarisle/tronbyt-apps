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
load("images/star_filled.webp", STAR_FILLED_ASSET = "file")
load("images/star_empty.webp", STAR_EMPTY_ASSET = "file")

CACHE_TIMEOUT = 43200  # 12 hours
MAX_CHARS_PER_LINE = 12  # approximate chars that fit in 64px width
DEFAULT_TEXT_SPEED = "100"

# Load star icons
STAR_FILLED = STAR_FILLED_ASSET.readall()
STAR_EMPTY = STAR_EMPTY_ASSET.readall()

# Modern color palette
COLOR_HEADER = "#E8F5E9"        # Light mint green
COLOR_RATING = "#FFC107"        # Modern amber/gold
COLOR_DATE = "#81D4FA"          # Modern light cyan
COLOR_USER = "#FFB74D"          # Warm orange
COLOR_SNIPPET = "#CE93D8"       # Modern purple

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
    review = reviews[random.number(0, review_count - 1)]

    rating = review.get("rating")
    date = review.get("date", "Unknown")
    user_name = review.get("user", {}).get("name", "Anonymous")
    snippet = review.get("snippet", "No comment provided")

    # Format rating display
    rating_int = 0
    if rating:
        rating_int = int(rating)

    return render.Root(
        delay = int(config.str("text_speed", DEFAULT_TEXT_SPEED)),
        child = render.Marquee(
            width = 64,
            height = 32,
            scroll_direction = "vertical",
            align = "center",
            child = render.Column(
                cross_align = "center",
                children = [
                    # Header
                    render.Text(
                        content = place_name,
                        color = COLOR_HEADER,
                        font = "CG-pixel-3x5-mono",
                    ),
                    render.Text(content = ""),

                    # Rating with multiple stars
                    render.Row(
                        main_align = "center",
                        cross_align = "center",
                        children = build_star_row(rating_int if rating else 0),
                    ),
                    render.Text(content = ""),

                    # Date
                    render.Text(
                        content = "Date: " + date,
                        color = COLOR_DATE,
                        font = "CG-pixel-3x5-mono",
                    ),
                    render.Text(content = ""),

                    # User Name
                    render.Text(
                        content = "By: " + user_name,
                        color = COLOR_USER,
                        font = "CG-pixel-3x5-mono",
                    ),
                    render.Text(content = ""),

                    # Snippet
                    render.WrappedText(
                        content = word_wrap(snippet, MAX_CHARS_PER_LINE),
                        color = COLOR_SNIPPET,
                        width = 64,
                    ),
                ],
            ),
        ),
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

"""
Applet: Google Review
Summary: Display Google Maps reviews
Description: Shows the latest Google Maps review with rating, date, reviewer name, and snippet.
Author: Tronbyt
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")

CACHE_TIMEOUT = 43200  # 12 hours
MAX_CHARS_PER_LINE = 12  # approximate chars that fit in 64px width
DEFAULT_TEXT_SPEED = "100"

# SerpAPI Google Maps Reviews endpoint
API_URL = "https://serpapi.com/search.json?engine=google_maps_reviews&data_id=0x4712a02b9c18c30b%3A0x620054ad98788b5a&sort_by=newestFirst&api_key=ef88d8e5775677bac44dfbe9c931f12aaf1d432c344b861d61267b9cef58080e"

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

    if not api_key:
        return render_error("No API key provided")

    if not data_id:
        return render_error("No data_id provided")

    # Build API URL with provided API key and data_id
    api_url = "https://serpapi.com/search.json?engine=google_maps_reviews&data_id=" + data_id + "&sort_by=newestFirst&api_key=" + api_key

    # Fetch data from API
    response = http.get(api_url, ttl_seconds = CACHE_TIMEOUT)

    if response.status_code != 200:
        return render_error("API Error")

    data = response.json()

    # Get first review
    if data.get("reviews") and len(data["reviews"]) > 0:
        review = data["reviews"][0]
    else:
        return render_error("No reviews found")

    rating = review.get("rating")
    date = review.get("date", "Unknown")
    user_name = review.get("user", {}).get("name", "Anonymous")
    snippet = review.get("snippet", "No comment provided")

    # Format rating display
    if rating:
        rating_int = int(rating)
        rating_text = "*" * rating_int + "-" * (5 - rating_int) + " " + str(rating)
    else:
        rating_text = "No rating"

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
                    render.Text(
                        content = "GOOGLE REVIEW",
                        color = "#fff",
                        font = "CG-pixel-3x5-mono",
                    ),
                    render.Text(
                        content = "",
                    ),
                    render.Text(
                        content = rating_text,
                        color = "#FFD700",
                        font = "CG-pixel-3x5-mono",
                    ),
                    render.Text(
                        content = "",
                    ),
                    render.Text(
                        content = "Date: " + date,
                        color = "#00FF00",
                        font = "CG-pixel-3x5-mono",
                    ),
                    render.Text(
                        content = "",
                    ),
                    render.Text(
                        content = "By: " + user_name,
                        color = "#00FFFF",
                        font = "CG-pixel-3x5-mono",
                    ),
                    render.Text(
                        content = "",
                    ),
                    render.WrappedText(
                        content = word_wrap(snippet, MAX_CHARS_PER_LINE),
                        color = "#FF69B4",
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
                desc = "Your SerpAPI key for Google Maps Reviews",
                icon = "key",
            ),
            schema.Text(
                id = "data_id",
                name = "Google Maps Place ID",
                desc = "The data_id for the Google Maps place (from SerpAPI search result)",
                icon = "mapPin",
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

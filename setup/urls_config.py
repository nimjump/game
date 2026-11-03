#!/usr/bin/env python3
"""
urls_config — shared loader for setup/urls.ini.

Both apply_urls.py (pre-export) and build.py (post-export) read the client's
URLs through here, so there is exactly one parser and one set of validation
rules. Standard library only, same as the rest of setup/.
"""
import configparser
import pathlib
import sys

CONFIG_FILENAME = "urls.ini"

# Placeholders written into the template files. build.py swaps these for the
# real values when it finishes the export folder.
GAME_URL_PLACEHOLDER = "__GAME_URL__"
API_BASE_PLACEHOLDER = "__API_BASE__"


class UrlConfigError(Exception):
    """Raised when urls.ini is missing, malformed, or has an unusable value."""


def config_path() -> pathlib.Path:
    """setup/urls.ini, resolved relative to this file — not the cwd, so the
    scripts work no matter which folder you run them from."""
    return pathlib.Path(__file__).resolve().parent / CONFIG_FILENAME


def _clean(raw: str, key: str) -> str:
    value = raw.strip().rstrip("/")
    if not value:
        raise UrlConfigError(f"'{key}' in {CONFIG_FILENAME} is empty.")
    if not (value.startswith("http://") or value.startswith("https://")):
        raise UrlConfigError(
            f"'{key}' in {CONFIG_FILENAME} must start with http:// or https:// "
            f"(got: {value!r})"
        )
    return value


def load_urls() -> tuple[str, str]:
    """Returns (api_base, game_url), both without a trailing slash.

    Raises UrlConfigError with a message meant to be shown straight to the
    user — every caller just prints it and exits.
    """
    path = config_path()
    if not path.is_file():
        raise UrlConfigError(
            f"{path} not found.\n"
            f"  This file is the single source of truth for the project's URLs.\n"
            f"  Create it with an [urls] section containing api_base and game_url."
        )

    parser = configparser.ConfigParser()
    try:
        parser.read(path, encoding="utf-8")
    except configparser.Error as exc:
        raise UrlConfigError(f"Couldn't parse {path}: {exc}") from exc

    if not parser.has_section("urls"):
        raise UrlConfigError(f"{path} has no [urls] section.")

    try:
        api_base = _clean(parser.get("urls", "api_base"), "api_base")
        game_url = _clean(parser.get("urls", "game_url"), "game_url")
    except configparser.NoOptionError as exc:
        raise UrlConfigError(f"{path} is missing a key: {exc}") from exc

    return api_base, game_url


def load_urls_or_exit() -> tuple[str, str]:
    """load_urls() with the standard 'print the problem and stop' behaviour
    both scripts want — a bad urls.ini should never silently produce a build
    pointing at the wrong domain."""
    try:
        return load_urls()
    except UrlConfigError as exc:
        print(f"\nURL CONFIG ERROR\n  {exc}\n", file=sys.stderr)
        sys.exit(1)


# ── Optional URLs ────────────────────────────────────────────────────────────
# Keys that are NOT needed by every consumer (build.py's SEO pass only cares
# about api_base/game_url) live here, in their own loaders, so adding one never
# changes load_urls()'s signature for existing callers.
DEFAULT_SHOP_URL = "https://shop.nimiqbase.com"


def load_shop_url() -> str:
    """Returns shop_url from urls.ini (no trailing slash).

    Falls back to DEFAULT_SHOP_URL when the key is absent, so an older
    urls.ini in someone's checkout still builds — a missing shop link should
    never be the reason `apply_urls.py` refuses to run.
    """
    path = config_path()
    if not path.is_file():
        return DEFAULT_SHOP_URL
    parser = configparser.ConfigParser()
    try:
        parser.read(path, encoding="utf-8")
    except configparser.Error as exc:
        raise UrlConfigError(f"Couldn't parse {path}: {exc}") from exc
    if not parser.has_section("urls") or not parser.has_option("urls", "shop_url"):
        return DEFAULT_SHOP_URL
    return _clean(parser.get("urls", "shop_url"), "shop_url")


def load_shop_url_or_exit() -> str:
    """load_shop_url() with the same print-and-exit behaviour as its sibling."""
    try:
        return load_shop_url()
    except UrlConfigError as exc:
        print(f"\nURL CONFIG ERROR\n  {exc}\n", file=sys.stderr)
        sys.exit(1)

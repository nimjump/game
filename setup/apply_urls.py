#!/usr/bin/env python3
"""
apply_urls — push the URLs from setup/urls.ini into the Godot client.

RUN THIS BEFORE EXPORTING. ApiConfig.gd's PROD_BASE / PROD_GAME_URL are
compiled into the exported build, so editing them after an export does
nothing until you export again.

It reads api_base / game_url from setup/urls.ini and rewrites the two
`const` lines in game/scripts/ApiConfig.gd in place. Only those two lines
are touched.

Everything else on the client side (robots.txt, sitemap.xml, the SEO tags
and the client-log API base in index.html) is placeholder-based and gets
filled in by build.py after the export.

The backend and admin panel are not this script's business — they read
their own URLs from their own .env files.

Usage:
  python setup/apply_urls.py            # apply
  python setup/apply_urls.py --check    # verify only, exit 1 if out of sync
"""
import pathlib
import re
import sys

# See the same note in build.py — make the sibling import work under every
# launcher, not just the plain `python setup/apply_urls.py` case.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from urls_config import load_urls_or_exit

# game/scripts/ApiConfig.gd, relative to this script's parent folder (repo root).
APICONFIG_RELPATH = pathlib.Path("game") / "scripts" / "ApiConfig.gd"

# Matches:  const PROD_BASE     := "https://..."   # optional trailing comment
# Captures the leading `const NAME <spaces>:= ` so the original alignment and
# any trailing comment survive the rewrite untouched.
_CONST_RE_TEMPLATE = r'^(\s*const\s+{name}\s*:=\s*)"[^"]*"'


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent


def _replace_const(text: str, name: str, value: str) -> tuple[str, bool, str]:
    """Returns (new_text, changed, old_value)."""
    pattern = re.compile(_CONST_RE_TEMPLATE.format(name=re.escape(name)), re.MULTILINE)
    match = pattern.search(text)
    if not match:
        raise SystemExit(
            f"\nCouldn't find `const {name} := \"...\"` in {APICONFIG_RELPATH}.\n"
            f"  If that constant was renamed or reformatted, update apply_urls.py\n"
            f"  to match — refusing to guess rather than corrupt the file.\n"
        )
    old_value = re.search(r'"([^"]*)"', match.group(0)).group(1)
    new_text = pattern.sub(lambda m: f'{m.group(1)}"{value}"', text, count=1)
    return new_text, old_value != value, old_value


def main():
    check_only = "--check" in sys.argv[1:]

    api_base, game_url = load_urls_or_exit()
    path = repo_root() / APICONFIG_RELPATH

    if not path.is_file():
        print(f"Not found: {path}", file=sys.stderr)
        sys.exit(1)

    text = path.read_text(encoding="utf-8")
    original = text

    text, base_changed, old_base = _replace_const(text, "PROD_BASE", api_base)
    text, game_changed, old_game = _replace_const(text, "PROD_GAME_URL", game_url)

    print(f"setup/urls.ini →")
    print(f"  api_base  = {api_base}")
    print(f"  game_url  = {game_url}\n")

    if text == original:
        print(f"{APICONFIG_RELPATH} is already in sync — nothing to do.")
    elif check_only:
        print(f"OUT OF SYNC — {APICONFIG_RELPATH} does not match urls.ini:")
        if base_changed:
            print(f"  PROD_BASE      {old_base}  →  {api_base}")
        if game_changed:
            print(f"  PROD_GAME_URL  {old_game}  →  {game_url}")
        print("\nRun `python setup/apply_urls.py` (without --check) to fix, "
              "then re-export.")
        sys.exit(1)
    else:
        path.write_text(text, encoding="utf-8")
        print(f"Updated {APICONFIG_RELPATH}:")
        if base_changed:
            print(f"  PROD_BASE      {old_base}  →  {api_base}")
        if game_changed:
            print(f"  PROD_GAME_URL  {old_game}  →  {game_url}")
        print("\nRe-export the game in Godot for this to take effect.")


if __name__ == "__main__":
    main()

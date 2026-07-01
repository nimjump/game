#!/usr/bin/env python3
"""
build — Compress Godot WebAssembly exports and finish the export folder.

For every .wasm file found:
  1. Produces .wasm.gz (gzip q9) and .wasm.br (brotli q5) next to it.
  2. Deletes the original uncompressed .wasm, then renames the .wasm.br
     file back to .wasm. The file the browser requests (index.wasm) is
     now Brotli-compressed bytes under its original name — that's what
     lets the _headers rule (Content-Encoding: br) work, since
     Cloudflare Pages serves whatever file is actually at that path
     rather than negotiating content on the fly. The .wasm.gz sits
     alongside as a spare/reference copy but isn't what gets requested.

Then copies the deploy-time extras from game/template into the export
folder:
  - _headers
  - assets/ (whole folder)

Requirements:  pip install brotli

Usage:
  python build.py                 # auto-finds ../export (relative to this script)
  python build.py path/to/folder  # explicit override
"""
import sys, gzip, shutil, pathlib

GZIP_LEVEL   = 9
BROTLI_LEVEL = 5   # fast; q11 takes minutes on large wasm files

# The export folder this script looks in by default: a sibling-level
# "export" folder one directory up from wherever this script lives
# (i.e. this script sits in some inner folder, "export" is next to
# that folder's parent — NOT relative to the current working directory,
# so it works the same no matter where you call it from).
DEFAULT_EXPORT_DIRNAME = "export"

# Where the deploy-time extras (_headers, assets/) live, relative to
# this script's own directory.
TEMPLATE_DIRNAME = pathlib.Path("game") / "template"


def gzip_file(path: pathlib.Path):
    out = path.parent / (path.name + ".gz")
    with open(path, "rb") as fi, gzip.open(out, "wb", compresslevel=GZIP_LEVEL) as fo:
        shutil.copyfileobj(fi, fo)
    ratio = 100 * (1 - out.stat().st_size / path.stat().st_size)
    print(f"  gzip   → {out.name}  ({out.stat().st_size/1e6:.1f} MB, -{ratio:.1f}%)")


def brotli_file(path: pathlib.Path):
    try:
        import brotli
    except ImportError:
        print("  brotli skipped — pip install brotli")
        return
    out = path.parent / (path.name + ".br")
    print(f"  brotli compressing (q{BROTLI_LEVEL})...", end=" ", flush=True)
    compressed = brotli.compress(path.read_bytes(), quality=BROTLI_LEVEL)
    out.write_bytes(compressed)
    ratio = 100 * (1 - out.stat().st_size / path.stat().st_size)
    print(f"→ {out.name}  ({out.stat().st_size/1e6:.1f} MB, -{ratio:.1f}%)")


def find_default_export_folder() -> pathlib.Path:
    """
    Look for an "export" folder one level up from this script's own
    directory, e.g.:
        NimJump/
        ├── export/          <- target
        └── tools/
            └── build.py
    Falls back to searching one level up from the current working
    directory if the script-relative guess doesn't exist, so it still
    works if the script gets copied around.
    """
    script_dir = pathlib.Path(__file__).resolve().parent
    candidate = script_dir.parent / DEFAULT_EXPORT_DIRNAME
    if candidate.is_dir():
        return candidate
    cwd_candidate = pathlib.Path.cwd().parent / DEFAULT_EXPORT_DIRNAME
    if cwd_candidate.is_dir():
        return cwd_candidate
    # Nothing found — return the primary guess anyway so the error
    # message below tells the user exactly where it looked.
    return candidate


def find_template_folder() -> pathlib.Path:
    """
    Look for game/template one level up from this script's own
    directory (same base as find_default_export_folder), falling back
    to the current working directory's parent if that doesn't exist.
    """
    script_dir = pathlib.Path(__file__).resolve().parent
    candidate = script_dir.parent / TEMPLATE_DIRNAME
    if candidate.is_dir():
        return candidate
    cwd_candidate = pathlib.Path.cwd().parent / TEMPLATE_DIRNAME
    if cwd_candidate.is_dir():
        return cwd_candidate
    return candidate


def copy_template_extras(export_folder: pathlib.Path, template_folder: pathlib.Path):
    """
    Copies _headers and assets/ from game/template into the export
    folder, overwriting whatever is already there.
    """
    if not template_folder.is_dir():
        print(f"Template folder not found: {template_folder.resolve()}")
        print("  Skipping _headers/assets copy — check the game/template path.")
        return

    headers_src = template_folder / "_headers"
    if headers_src.is_file():
        headers_dst = export_folder / "_headers"
        shutil.copyfile(headers_src, headers_dst)
        print(f"  copied _headers → {headers_dst}")
    else:
        print(f"  no _headers found in {template_folder.resolve()}, skipped")

    assets_src = template_folder / "assets"
    if assets_src.is_dir():
        assets_dst = export_folder / "assets"
        if assets_dst.exists():
            shutil.rmtree(assets_dst)
        shutil.copytree(assets_src, assets_dst)
        print(f"  copied assets/ → {assets_dst}")
    else:
        print(f"  no assets/ folder found in {template_folder.resolve()}, skipped")


def main():
    if len(sys.argv) > 1:
        folder = pathlib.Path(sys.argv[1])
    else:
        folder = find_default_export_folder()
        print(f"No path given — looking for '{DEFAULT_EXPORT_DIRNAME}' folder: {folder.resolve()}\n")

    if not folder.is_dir():
        print(f"Folder not found: {folder.resolve()}")
        print(f"Pass an explicit path instead: python {pathlib.Path(__file__).name} path/to/export/folder")
        sys.exit(1)

    files = [w for w in sorted(folder.rglob("*.wasm")) if not w.name.endswith(".opt.wasm")]
    if not files:
        print(f"No .wasm files found in {folder.resolve()}")
        sys.exit(1)

    print(f"Found {len(files)} .wasm file(s) in {folder.resolve()}:\n")
    for wasm in files:
        print(f"[{wasm.name}]  ({wasm.stat().st_size/1e6:.1f} MB)")
        gzip_file(wasm)
        brotli_file(wasm)

        br_path = wasm.parent / (wasm.name + ".br")
        wasm.unlink()
        if br_path.is_file():
            br_path.rename(wasm)
            print(f"  renamed {br_path.name} → {wasm.name}")
            print(f"  (the file at {wasm.name} is now Brotli-compressed bytes;")
            print(f"   _headers tells Cloudflare it's already br-encoded)")
        else:
            print(f"  WARNING: {br_path.name} missing — is brotli installed? "
                  f"index.wasm has been deleted with nothing to replace it, "
                  f"the game will 404 until this is fixed.")
        print()

    template_folder = find_template_folder()
    print(f"Copying deploy extras from {template_folder.resolve()} into {folder.resolve()}:\n")
    copy_template_extras(folder, template_folder)

    print("\nDone. export/ is ready to upload to Cloudflare Pages.")


if __name__ == "__main__":
    main()
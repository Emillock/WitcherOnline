"""Build pipeline for the Gwent duels board on The Witcher 3 5.01.

usage:
  build.py tools                               download, verify and unpack the pinned tools
  build.py vanilla --game <dir> [--out <file>] [--allow-unknown-board]
                                               extract the vanilla board to gwent/work/vanilla.redswf

The game folder is only ever read.
"""
import argparse
import hashlib
import sys
from pathlib import Path

import bundle
import tools

GWENT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_VANILLA_OUT = GWENT_DIR / "work" / "vanilla.redswf"

GUI_BUNDLE = Path("content") / "content0" / "bundles" / "r4gui.bundle"
BOARD_ENTRY = "gameplay\\gui_new\\swf\\gwint\\gwint_game.redswf"

# Game build -> sha256 of the vanilla gwint_game.redswf shipped with it.
KNOWN_BOARDS = {
    "5.0.0.1048522": "aeb1255be5a4d218bf41a7630dd27e4b25b32936c0f06055fa77e7aec4d5664e",
}


def extract_vanilla(game: Path, out: Path, allow_unknown: bool) -> int:
    """Writes the vanilla board from the game's r4gui.bundle to out; returns the exit code."""
    bundle_path = game / GUI_BUNDLE
    if not bundle_path.is_file():
        print(f"error: {bundle_path} not found", file=sys.stderr)
        return 1
    try:
        board = bundle.extract(bundle_path, BOARD_ENTRY)
    except bundle.BundleError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    digest = hashlib.sha256(board).hexdigest()
    known = [game_build for game_build, sha in KNOWN_BOARDS.items() if sha == digest]
    if known:
        print(f"board matches game build {known[0]}")
    elif allow_unknown:
        print(f"warning: board sha256 {digest} is not a known board", file=sys.stderr)
    else:
        print(f"error: board sha256 {digest} is not a known board "
              f"(pass --allow-unknown-board to extract it anyway)", file=sys.stderr)
        return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(board)
    print(f"wrote {out} ({len(board)} bytes, sha256 {digest})")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Command line entry point."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("tools", help="download, verify and unpack the pinned tools")
    vanilla = sub.add_parser("vanilla", help="extract the vanilla board from the game")
    vanilla.add_argument("--game", type=Path, required=True, help="The Witcher 3 game folder")
    vanilla.add_argument("--out", type=Path, default=DEFAULT_VANILLA_OUT)
    vanilla.add_argument("--allow-unknown-board", action="store_true",
                         help="extract a board whose sha256 is not in KNOWN_BOARDS")
    args = parser.parse_args(argv)
    if args.command == "tools":
        paths = tools.ensure()
        print(f"java: {paths.java}\nffdec-cli: {paths.ffdec_cli_jar}")
        return 0
    return extract_vanilla(args.game, args.out, args.allow_unknown_board)


if __name__ == "__main__":
    sys.exit(main())

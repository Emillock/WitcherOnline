"""Build pipeline for the Gwent duels board on The Witcher 3 5.01.

usage:
  build.py tools                               download, verify and unpack the pinned tools
  build.py vanilla --game <dir> [--out <file>] [--allow-unknown-board]
                                               extract the vanilla board to gwent/work/vanilla.redswf
  build.py build --game <dir> [--out <dir>] [--work <dir>] [--allow-unknown-board]
                                               decompile, patch, add our classes, recompile and write
                                               <out>/modWitcherOnline/content/{blob0.bundle,metadata.store}
  build.py diff [--work <dir>]                 regenerate gwent/patches/*.patch from <work>/edit against
                                               <work>/vanilla (copy vanilla to edit and change edit first)

The game folder is only ever read.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import bundle
import ffdec
import patches
import redswf
import tools

GWENT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_WORK = GWENT_DIR / "work"
DEFAULT_OUT = GWENT_DIR / "out"
DEFAULT_VANILLA_OUT = DEFAULT_WORK / "vanilla.redswf"
SRC_DIR = GWENT_DIR / "src"
PATCH_DIR = GWENT_DIR / "patches"

MOD_NAME = "modWitcherOnline"
HOST_SCRIPT = Path("red") / "game" / "witcher3" / "menus" / "gwint" / "CardTransaction.as"

GUI_BUNDLE = Path("content") / "content0" / "bundles" / "r4gui.bundle"
BOARD_ENTRY = "gameplay\\gui_new\\swf\\gwint\\gwint_game.redswf"

# Game build -> sha256 of the vanilla gwint_game.redswf shipped with it.
KNOWN_BOARDS = {
    "5.0.0.1048522": "aeb1255be5a4d218bf41a7630dd27e4b25b32936c0f06055fa77e7aec4d5664e",
}


class BuildError(Exception):
    """A pipeline step failed in a way the user can act on."""


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


def _git(args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    """Runs git as if cwd were outside any repository, so patch paths are relative to cwd."""
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(cwd.resolve().parent))
    return subprocess.run(
        ["git", "-c", "core.longpaths=true", *args], cwd=cwd, env=env,
        capture_output=True, text=True, encoding="utf-8", errors="replace", check=False)


def _script_files(root: Path) -> list[Path]:
    """Returns the .as files under root as paths relative to it, sorted."""
    return sorted(path.relative_to(root) for path in root.rglob("*.as"))


def changed_files(vanilla: Path, edited: Path) -> list[Path]:
    """Returns the relative paths of scripts in edited that are new or differ from vanilla."""
    changed = []
    for rel in _script_files(edited):
        original = vanilla / rel
        if not original.is_file() or original.read_bytes() != (edited / rel).read_bytes():
            changed.append(rel)
    return changed


def write_patches(vanilla: Path, edited: Path, patch_dir: Path) -> list[str]:
    """Writes one `<Class>.patch` per script that differs, replacing the old ones; returns their names.

    The patches are `git diff` output with the directory prefixes rewritten to `a/` and `b/`,
    so `git apply -p1` works from the scripts root.
    """
    patch_dir.mkdir(parents=True, exist_ok=True)
    pending: list[tuple[str, str]] = []
    for rel in changed_files(vanilla, edited):
        if not (vanilla / rel).is_file():
            raise BuildError(f"{rel} is new; new classes belong in gwent/src, not in a patch")
        posix = rel.as_posix()
        result = _git(["diff", "--no-index", "--no-color", "--src-prefix=a/", "--dst-prefix=b/",
                       "--", f"vanilla/{posix}", f"edit/{posix}"], cwd=vanilla.parent)
        if result.returncode not in (0, 1) or not result.stdout:
            raise BuildError(f"git diff failed for {posix}: {result.stderr}")
        text = result.stdout.replace(f"a/vanilla/{posix}", f"a/{posix}")
        text = text.replace(f"b/edit/{posix}", f"b/{posix}")
        name = f"{rel.stem}.patch"
        if any(name == taken for taken, _ in pending):
            raise BuildError(f"two patched scripts are called {rel.stem}")
        pending.append((name, text))
    for stale in patch_dir.glob("*.patch"):
        stale.unlink()
    for name, text in pending:
        (patch_dir / name).write_text(text, encoding="utf-8", newline="\n")
    return [name for name, _ in pending]


def apply_patches(target: Path, patch_dir: Path) -> list[str]:
    """Applies every `*.patch` in patch_dir to the script tree at target; returns their names."""
    applied = []
    for patch in sorted(patch_dir.glob("*.patch")):
        result = _git(["apply", "-p1", "--whitespace=nowarn", str(patch.resolve())], cwd=target)
        if result.returncode != 0:
            raise BuildError(f"{patch.name} does not apply:\n{result.stdout}{result.stderr}")
        applied.append(patch.name)
    return applied


def _stage_changed(build_dir: Path, vanilla: Path, import_dir: Path) -> list[Path]:
    """Copies the scripts that differ from vanilla into a fresh import_dir; returns their paths."""
    shutil.rmtree(import_dir, ignore_errors=True)
    changed = changed_files(vanilla, build_dir)
    for rel in changed:
        (import_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(build_dir / rel, import_dir / rel)
    return changed


def _host_classes(build_dir: Path) -> int:
    """Appends every gwent/src class to the host script in build_dir; returns how many files."""
    sources = sorted(SRC_DIR.glob("*.as"))
    host_path = build_dir / HOST_SCRIPT
    merged = patches.host(
        host_path.read_text(encoding="utf-8"),
        [source.read_text(encoding="utf-8") for source in sources])
    host_path.write_text(merged, encoding="utf-8", newline="\n")
    return len(sources)


def build_mod(game: Path, out: Path, work: Path, allow_unknown: bool) -> int:
    """Runs the whole pipeline and writes the mod bundle under out; returns the exit code."""
    started = time.monotonic()
    work.mkdir(parents=True, exist_ok=True)
    vanilla_path = work / "vanilla.redswf"
    status = extract_vanilla(game, vanilla_path, allow_unknown)
    if status:
        return status
    vanilla_data = vanilla_path.read_bytes()

    movie = redswf.read_movie(vanilla_data)
    vanilla_swf = work / "vanilla.swf"
    vanilla_swf.write_bytes(movie.fws)
    print("decompiling the vanilla board")
    ffdec.export_scripts(vanilla_swf, work / "vanilla")

    build_dir = work / "build"
    shutil.rmtree(build_dir, ignore_errors=True)
    shutil.copytree(work / "vanilla", build_dir)
    applied = apply_patches(build_dir, PATCH_DIR)
    print(f"applied {len(applied)} patch(es): {', '.join(applied) or 'none'}")
    hosted = _host_classes(build_dir)
    print(f"hosted {hosted} class file(s) in {HOST_SCRIPT.name}")

    changed = _stage_changed(build_dir, work / "vanilla", work / "import")
    print(f"recompiling {len(changed)} script(s): {', '.join(p.stem for p in changed)}")
    built_swf = work / "build.swf"
    ffdec.import_scripts(vanilla_swf, work / "import", built_swf)

    fws = built_swf.read_bytes()
    if fws[3] != movie.version:
        fws = fws[:3] + bytes([movie.version]) + fws[4:]
    board = redswf.rewrap(vanilla_data, fws)
    redswf.check_consistency(board)
    (work / "gwint_game.redswf").write_bytes(board)

    content = out / MOD_NAME / "content"
    shutil.rmtree(out / MOD_NAME, ignore_errors=True)
    content.mkdir(parents=True)
    bundle.write_v3(content / "blob0.bundle", [(BOARD_ENTRY, board)])
    bundle.write_metadata(content / "metadata.store", [content / "blob0.bundle"])
    print(f"wrote {content / 'blob0.bundle'} and metadata.store "
          f"in {time.monotonic() - started:.0f} s")
    return 0


def diff_patches(work: Path) -> int:
    """Regenerates gwent/patches from work/edit against work/vanilla; returns the exit code."""
    vanilla, edited = work / "vanilla", work / "edit"
    for folder in (vanilla, edited):
        if not folder.is_dir():
            print(f"error: {folder} not found (run `build.py build`, then copy vanilla to edit)",
                  file=sys.stderr)
            return 1
    names = write_patches(vanilla, edited, PATCH_DIR)
    print(f"wrote {len(names)} patch(es) to {PATCH_DIR}: {', '.join(names) or 'none'}")
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
    full = sub.add_parser("build", help="decompile, patch, recompile and write the mod bundle")
    full.add_argument("--game", type=Path, required=True, help="The Witcher 3 game folder")
    full.add_argument("--out", type=Path, default=DEFAULT_OUT)
    full.add_argument("--work", type=Path, default=DEFAULT_WORK)
    full.add_argument("--allow-unknown-board", action="store_true",
                      help="build on a board whose sha256 is not in KNOWN_BOARDS")
    diff = sub.add_parser("diff", help="regenerate gwent/patches from work/edit")
    diff.add_argument("--work", type=Path, default=DEFAULT_WORK)
    args = parser.parse_args(argv)
    try:
        if args.command == "tools":
            paths = tools.ensure()
            print(f"java: {paths.java}\nffdec-cli: {paths.ffdec_cli_jar}")
            return 0
        if args.command == "build":
            return build_mod(args.game, args.out, args.work, args.allow_unknown_board)
        if args.command == "diff":
            return diff_patches(args.work)
        return extract_vanilla(args.game, args.out, args.allow_unknown_board)
    except (BuildError, ffdec.FFDecError, patches.PatchError, redswf.RedswfError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

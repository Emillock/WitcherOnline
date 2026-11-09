"""Thin wrapper around the pinned FFDec command line: export, import and list AS3 scripts.

FFDec reads plain (FWS) and zlib (CWS) movies, not Scaleform's CFX, so callers feed it the
FWS bytes from `redswf.read_movie`. Exported scripts are normalised to LF line endings so
patches written against them apply the same on every platform.
"""
import shutil
import struct
import subprocess
import zlib
from pathlib import Path

import tools

FFDEC_TIMEOUT_SECONDS = 900
FWS_MAGIC = b"FWS"
CWS_MAGIC = b"CWS"
SWF_HEADER_SIZE = 8
SCRIPTS_SUBDIR = "scripts"
IMPORT_FAILURE_MARKER = "SEVERE"


class FFDecError(Exception):
    """FFDec failed, or produced output this module cannot use."""


def _run(args: list[str], paths: tools.ToolPaths | None = None) -> str:
    """Runs the FFDec CLI with args and returns its stdout. Raises FFDecError on a non-zero exit."""
    paths = paths or tools.ensure()
    command = [str(paths.java), "-Djava.awt.headless=true", "-jar", str(paths.ffdec_cli_jar), *args]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=FFDEC_TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired as error:
        raise FFDecError(f"ffdec {args[0]} timed out after {FFDEC_TIMEOUT_SECONDS} s") from error
    if result.returncode != 0:
        raise FFDecError(
            f"ffdec {args[0]} exited with {result.returncode}:\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


def _normalise_line_endings(root: Path) -> None:
    """Rewrites every .as file under root with LF line endings."""
    for script in root.rglob("*.as"):
        raw = script.read_bytes()
        fixed = raw.replace(b"\r\n", b"\n")
        if fixed != raw:
            script.write_bytes(fixed)


def export_scripts(swf: Path, out_dir: Path) -> None:
    """Decompiles every AS3 script of swf into out_dir as `<package path>/<Class>.as` (LF endings).

    out_dir is emptied first. FFDec nests its output in a `scripts` folder; that level is removed.
    """
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    _run(["-export", "script", str(out_dir), str(swf)])
    nested = out_dir / SCRIPTS_SUBDIR
    if nested.is_dir():
        for child in nested.iterdir():
            child.replace(out_dir / child.name)
        nested.rmdir()
    if not any(out_dir.rglob("*.as")):
        raise FFDecError(f"ffdec exported no scripts from {swf}")
    _normalise_line_endings(out_dir)


def _as_fws(data: bytes) -> bytes:
    """Returns the movie uncompressed: a CWS movie is inflated, an FWS movie is returned as is."""
    if data[:3] == FWS_MAGIC:
        return data
    if data[:3] != CWS_MAGIC or len(data) < SWF_HEADER_SIZE:
        raise FFDecError("ffdec wrote something that is neither an FWS nor a CWS movie")
    body = zlib.decompress(data[SWF_HEADER_SIZE:])
    declared = struct.unpack_from("<I", data, 4)[0]
    if declared != SWF_HEADER_SIZE + len(body):
        raise FFDecError("CWS movie length does not match its decompressed size")
    return FWS_MAGIC + data[3:SWF_HEADER_SIZE] + body


def import_scripts(swf: Path, scripts_dir: Path, out_swf: Path) -> None:
    """Recompiles the scripts under scripts_dir into a copy of swf written to out_swf (always FWS).

    Only the classes present in scripts_dir are replaced. A script file that holds a second
    class of the same package registers that class as well, which is how new classes are added.
    """
    out_swf.parent.mkdir(parents=True, exist_ok=True)
    out_swf.unlink(missing_ok=True)
    log = _run(["-importScript", str(swf), str(out_swf), str(scripts_dir)])
    if not out_swf.is_file():
        raise FFDecError(f"ffdec wrote no output movie:\n{log}")
    if IMPORT_FAILURE_MARKER in log:
        raise FFDecError(f"ffdec reported a problem while importing scripts:\n{log}")
    out_swf.write_bytes(_as_fws(out_swf.read_bytes()))


def dump_as3(swf: Path) -> list[str]:
    """Returns the fully qualified names of every AS3 class (script) in swf."""
    names = []
    for line in _run(["-dumpAS3", str(swf)]).splitlines():
        name, _, index = line.strip().rpartition(" ")
        if name and index.isdigit():
            names.append(name)
    return names

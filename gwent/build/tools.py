"""Pinned external tools for the Gwent build: FFDec and a Java runtime.

The patches depend on FFDec's exact decompiler output, so both tools are pinned
by URL and sha256. A zip already present in the tools folder is reused when its
checksum matches; the network is only touched when it is missing or wrong.
"""
import hashlib
import os
import shutil
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent.parent / ".tools"
CHUNK = 1 << 20
DOWNLOAD_TIMEOUT_SECONDS = 60


class ToolChecksumError(Exception):
    """A tool archive does not match its pinned sha256."""


class ToolLayoutError(Exception):
    """An unpacked tool archive lacks the file the build needs."""


@dataclass(frozen=True)
class Pin:
    """One pinned download: where it comes from, what it must hash to, and its local zip name."""

    name: str
    url: str
    sha256: str
    zip_name: str


@dataclass(frozen=True)
class ToolPaths:
    """Executable locations of the unpacked tools."""

    java: Path
    ffdec_cli_jar: Path


FFDEC = Pin(
    name="ffdec",
    url="https://github.com/jindrapetrik/jpexs-decompiler/releases/download/version26.4.0/ffdec_26.4.0.zip",
    sha256="56ce960aeafc7caf034e2052ba49f878a883f7c7ca690da6eeffca9587b5e4b9",
    zip_name="ffdec.zip",
)
JRE = Pin(
    name="jre",
    url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip",
    sha256="2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628",
    zip_name="jre.zip",
)


def sha256_of(path: Path) -> str:
    """Returns the hex sha256 of a file."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def verify(path: Path, expected_sha256: str) -> None:
    """Raises ToolChecksumError unless the file hashes to expected_sha256."""
    actual = sha256_of(path)
    if actual != expected_sha256.lower():
        raise ToolChecksumError(
            f"{path.name}: sha256 {actual} does not match the pinned {expected_sha256}")


def _download(url: str, dest: Path) -> None:
    """Streams url into dest."""
    with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response, \
            open(dest, "wb") as out:
        shutil.copyfileobj(response, out, CHUNK)


def _pinned_zip(tools_dir: Path, pin: Pin) -> Path:
    """Returns the verified zip for the pin, downloading it only when missing or wrong."""
    zip_path = tools_dir / pin.zip_name
    if zip_path.is_file():
        try:
            verify(zip_path, pin.sha256)
            return zip_path
        except ToolChecksumError:
            zip_path.unlink()
    part = zip_path.with_suffix(zip_path.suffix + ".part")
    try:
        _download(pin.url, part)
        verify(part, pin.sha256)
        part.replace(zip_path)
    finally:
        part.unlink(missing_ok=True)
    return zip_path


def _long_path(path: Path) -> str:
    """Returns path in a form that works past the 260 character Windows limit."""
    resolved = str(path.resolve())
    if os.name == "nt" and not resolved.startswith("\\\\?\\"):
        return "\\\\?\\" + resolved
    return resolved


def _unpacked(tools_dir: Path, pin: Pin, zip_path: Path) -> Path:
    """Unzips the archive into its own folder next to it, once, and returns that folder."""
    target = tools_dir / pin.name
    marker = target / ".unpacked"
    if marker.is_file():
        return target
    staging = tools_dir / (pin.name + ".staging")
    shutil.rmtree(staging, ignore_errors=True)
    shutil.rmtree(target, ignore_errors=True)
    staging.mkdir(parents=True)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(_long_path(staging))
    (staging / ".unpacked").write_text(pin.sha256)
    staging.replace(target)
    return target


def _find_one(root: Path, pattern: str) -> Path:
    matches = sorted(root.glob(pattern))
    if not matches:
        raise ToolLayoutError(f"{pattern} not found under {root}")
    return matches[0]


def ensure(tools_dir: Path = TOOLS_DIR, ffdec_pin: Pin = FFDEC, jre_pin: Pin = JRE) -> ToolPaths:
    """Makes sure FFDec and the Java runtime are unpacked in tools_dir and returns their paths."""
    tools_dir.mkdir(parents=True, exist_ok=True)
    ffdec_root = _unpacked(tools_dir, ffdec_pin, _pinned_zip(tools_dir, ffdec_pin))
    jre_root = _unpacked(tools_dir, jre_pin, _pinned_zip(tools_dir, jre_pin))
    return ToolPaths(
        java=_find_one(jre_root, "*/bin/java.exe"),
        ffdec_cli_jar=_find_one(ffdec_root, "ffdec-cli.jar"),
    )

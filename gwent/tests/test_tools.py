"""Tests for the pinned tool download, verification and unpacking."""
import hashlib
import zipfile
from pathlib import Path

import pytest

import tools


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def test_verify_rejects_bad_checksum(tmp_path: Path) -> None:
    path = tmp_path / "tool.zip"
    path.write_bytes(b"not the pinned content")
    with pytest.raises(tools.ToolChecksumError):
        tools.verify(path, "0" * 64)


def test_verify_accepts_matching_checksum(tmp_path: Path) -> None:
    path = tmp_path / "tool.zip"
    path.write_bytes(b"pinned content")
    tools.verify(path, _sha256(b"pinned content"))


def test_pins_match_the_plan() -> None:
    assert tools.FFDEC.sha256 == "56ce960aeafc7caf034e2052ba49f878a883f7c7ca690da6eeffca9587b5e4b9"
    assert tools.JRE.sha256 == "2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628"
    assert tools.FFDEC.url.endswith("/version26.4.0/ffdec_26.4.0.zip")
    assert "jdk-21.0.13%2B9" in tools.JRE.url


def _make_zip(path: Path, members: dict[str, bytes]) -> str:
    with zipfile.ZipFile(path, "w") as z:
        for name, data in members.items():
            z.writestr(name, data)
    return _sha256(path.read_bytes())


def _fake_pins(tmp_path: Path) -> tuple[tools.Pin, tools.Pin, Path]:
    tools_dir = tmp_path / ".tools"
    tools_dir.mkdir()
    ffdec_sha = _make_zip(tools_dir / "ffdec.zip", {"ffdec-cli.jar": b"jar"})
    jre_sha = _make_zip(tools_dir / "jre.zip", {"jdk-x-jre/bin/java.exe": b"exe"})
    ffdec = tools.Pin("ffdec", "http://invalid.test/ffdec.zip", ffdec_sha, "ffdec.zip")
    jre = tools.Pin("jre", "http://invalid.test/jre.zip", jre_sha, "jre.zip")
    return ffdec, jre, tools_dir


def test_ensure_uses_present_zips_without_downloading(tmp_path: Path, monkeypatch) -> None:
    ffdec, jre, tools_dir = _fake_pins(tmp_path)

    def no_network(*args, **kwargs):
        raise AssertionError("ensure must not download when the pinned zips are present")

    monkeypatch.setattr(tools, "_download", no_network)
    paths = tools.ensure(tools_dir, ffdec_pin=ffdec, jre_pin=jre)
    assert paths.ffdec_cli_jar.read_bytes() == b"jar"
    assert paths.java.name == "java.exe"
    assert paths.java.read_bytes() == b"exe"
    assert tools.ensure(tools_dir, ffdec_pin=ffdec, jre_pin=jre) == paths


def test_ensure_redownloads_a_zip_with_wrong_checksum(tmp_path: Path, monkeypatch) -> None:
    ffdec, jre, tools_dir = _fake_pins(tmp_path)
    good = (tools_dir / "ffdec.zip").read_bytes()
    (tools_dir / "ffdec.zip").write_bytes(b"corrupt")
    calls: list[str] = []

    def fake_download(url: str, dest: Path) -> None:
        calls.append(url)
        dest.write_bytes(good)

    monkeypatch.setattr(tools, "_download", fake_download)
    tools.ensure(tools_dir, ffdec_pin=ffdec, jre_pin=jre)
    assert calls == [ffdec.url]


def test_ensure_rejects_a_download_with_wrong_checksum(tmp_path: Path, monkeypatch) -> None:
    ffdec, jre, tools_dir = _fake_pins(tmp_path)
    (tools_dir / "ffdec.zip").unlink()
    monkeypatch.setattr(tools, "_download", lambda url, dest: dest.write_bytes(b"tampered"))
    with pytest.raises(tools.ToolChecksumError):
        tools.ensure(tools_dir, ffdec_pin=ffdec, jre_pin=jre)
    assert not (tools_dir / "ffdec.zip").exists()

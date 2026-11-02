"""Merges our own AS3 classes into one vanilla host script.

FFDec's `-importScript` replaces existing script files but cannot add new ones, while a
second class placed in an existing script file of the same package compiles and registers
as its own class. `host` therefore appends the classes of our sources to the host script's
package block and folds their import lines into it.
"""
import re

INDENT = "   "
IMPORT_LINE = re.compile(r"^[ \t]*import[ \t]+([\w.*]+)[ \t]*;[ \t]*$", re.MULTILINE)
LEADING_BLANK_LINES = re.compile(r"\A(?:[ \t]*\n)+")
PACKAGE_OPEN = re.compile(r"^[ \t]*package\b[^{]*\{[ \t]*$", re.MULTILINE)


class PatchError(Exception):
    """A script does not have the package block shape this module expects."""


def _lf(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _package_bounds(text: str, what: str) -> tuple[int, int]:
    """Returns (index after the package's opening brace line, index of its closing brace)."""
    opening = PACKAGE_OPEN.search(text)
    closing = text.rstrip().rfind("}")
    if opening is None or closing < opening.end():
        raise PatchError(f"{what} has no package block")
    return opening.end(), closing


def _split_source(source: str) -> tuple[list[str], str]:
    """Returns (import names in order, class text) of one source's package block, or of the bare text."""
    text = _lf(source)
    if PACKAGE_OPEN.search(text):
        start, end = _package_bounds(text, "source")
        text = text[start:end]
    imports = IMPORT_LINE.findall(text)
    body = LEADING_BLANK_LINES.sub("", IMPORT_LINE.sub("", text))
    return imports, body.rstrip()


def host(host_text: str, sources: list[str]) -> str:
    """Returns host_text with every source's classes appended and their imports merged in.

    Imports already present in the host, or repeated across sources, appear once. The result
    uses LF line endings. Raises PatchError if the host has no package block.
    """
    text = _lf(host_text)
    start, end = _package_bounds(text, "host")
    if not sources:
        return text
    known = set(IMPORT_LINE.findall(text))
    new_imports: list[str] = []
    bodies: list[str] = []
    for source in sources:
        imports, body = _split_source(source)
        for name in imports:
            if name not in known:
                known.add(name)
                new_imports.append(name)
        if body.strip():
            bodies.append(body)

    package_block = text[start:end].rstrip()
    if new_imports:
        lines = "".join(f"{INDENT}import {name};\n" for name in new_imports)
        existing = list(IMPORT_LINE.finditer(package_block))
        if existing:
            cut = existing[-1].end()
            package_block = package_block[:cut] + "\n" + lines.rstrip("\n") + package_block[cut:]
        else:
            package_block = "\n" + lines + package_block
    merged = package_block + "".join("\n\n" + body for body in bodies)
    return text[:start] + merged + "\n" + text[end:]

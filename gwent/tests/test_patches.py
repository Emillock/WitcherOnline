"""Tests for gwent/build/patches.py: merging our classes into a vanilla host script."""
import pytest

import patches

HOST = """package red.game.witcher3.menus.gwint
{
   import a.B;
   
   public class Host
   {
      
      public var x:int;
   }
}
"""

SOURCE = """package red.game.witcher3.menus.gwint
{
   import a.B;
   import c.D;
   
   public class Extra
   {
      
      public function f(b:B, d:D) : void
      {
      }
   }
}
"""

BARE_HOST = """package p
{
   public class Host
   {
   }
}
"""


def balanced(text: str) -> bool:
    depth = 0
    for char in text:
        depth += (char == "{") - (char == "}")
        if depth < 0:
            return False
    return depth == 0


def test_host_merges_imports() -> None:
    merged = patches.host(HOST, [SOURCE])
    assert merged.count("import a.B;") == 1
    assert merged.count("import c.D;") == 1
    assert merged.count("package ") == 1
    assert "public class Host" in merged and "public class Extra" in merged
    assert merged.index("public class Host") < merged.index("public class Extra")
    assert merged.rstrip().endswith("}")
    assert balanced(merged)


def test_host_without_imports_gets_them_after_the_package_brace() -> None:
    merged = patches.host(BARE_HOST, [SOURCE])
    assert merged.index("import a.B;") < merged.index("public class Host")
    assert balanced(merged)


def test_host_dedupes_imports_across_sources() -> None:
    other = SOURCE.replace("Extra", "Other")
    merged = patches.host(HOST, [SOURCE, other])
    assert merged.count("import c.D;") == 1
    assert merged.index("public class Extra") < merged.index("public class Other")


def test_host_accepts_crlf_and_returns_lf() -> None:
    merged = patches.host(HOST.replace("\n", "\r\n"), [SOURCE.replace("\n", "\r\n")])
    assert "\r" not in merged
    assert balanced(merged)


def test_host_with_no_sources_is_unchanged() -> None:
    assert patches.host(HOST, []) == HOST


def test_host_rejects_text_without_a_package_block() -> None:
    with pytest.raises(patches.PatchError):
        patches.host("public class Host {}", [SOURCE])

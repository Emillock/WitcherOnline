"""Helpers for the tests that read the board's ActionScript sources."""


def function_body(text: str, signature: str) -> str:
    """The body of the first function whose declaration contains `signature` (brace matched)."""
    start = text.index(signature)
    open_at = text.index("{", start)
    depth = 0
    for index in range(open_at, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:index + 1]
    raise AssertionError(f"unbalanced braces after {signature}")

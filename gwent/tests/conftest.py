"""Makes the modules under gwent/build and gwent/tools importable from the tests."""
import sys
from pathlib import Path

GWENT_DIR = Path(__file__).resolve().parent.parent
for _dir in (GWENT_DIR / "build", GWENT_DIR / "tools"):
    if str(_dir) not in sys.path:
        sys.path.insert(0, str(_dir))


def pytest_configure(config) -> None:
    """Registers the `slow` marker for tests that run the real FFDec pipeline."""
    config.addinivalue_line("markers", "slow: runs the real decompile and recompile (minutes)")

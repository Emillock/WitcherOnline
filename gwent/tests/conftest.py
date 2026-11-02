"""Makes the build modules under gwent/build importable from the tests."""
import sys
from pathlib import Path

BUILD_DIR = Path(__file__).resolve().parent.parent / "build"
if str(BUILD_DIR) not in sys.path:
    sys.path.insert(0, str(BUILD_DIR))

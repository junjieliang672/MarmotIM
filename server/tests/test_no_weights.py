"""The done-criterion: `pytest` runs with the model mocked -- the whole suite without weights.

This asserts the mechanism rather than trusting it. `model.default_loader` is the single
place `qwen3_asr_mlx` is named, and it imports lazily *inside* the function; if anyone
hoists that import to module scope, the suite would still pass on a developer machine that
happens to have mlx installed, and fail on a clean one. These two tests fail loudly instead.
"""

from __future__ import annotations

import importlib
import sys


def test_no_model_library_is_imported_by_the_suite():
    # Every test module has already been collected and every app built by the time this
    # runs, so sys.modules is the record of what the server actually needed.
    for module in ("qwen3_asr_mlx", "mlx", "mlx.core", "mlx_metal", "soundfile", "torch"):
        assert module not in sys.modules, (
            f"{module} was imported -- the suite is no longer weights-free. The likely "
            f"cause is a module-scope import in model.py."
        )


def test_the_only_reference_to_the_library_is_inside_default_loader():
    import model

    source = importlib.import_module("model").__file__
    with open(source, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    # Prose mentions are fine and there are several; an *import statement* is the thing
    # that must stay indented inside a function.
    hits = [(i + 1, ln) for i, ln in enumerate(lines)
            if "qwen3_asr_mlx" in ln and ln.lstrip().startswith(("import ", "from "))]
    assert len(hits) == 1, f"expected exactly one import of the library, found {hits}"
    lineno, line = hits[0]
    assert line.startswith("    "), (
        f"model.py:{lineno} imports qwen3_asr_mlx at module scope: {line!r}"
    )
    assert model.default_loader.__module__ == "model"

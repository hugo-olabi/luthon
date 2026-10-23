"""Basic smoke tests for Luthon."""

from luthon import __version__
from luthon.main import main


def test_version() -> None:
    assert __version__ == "0.1.0"


def test_main_runs(capsys) -> None:
    main([])
    captured = capsys.readouterr()
    assert "luthon" in captured.out.lower()

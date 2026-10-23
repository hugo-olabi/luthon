"""Entry point for the Luthon application."""

from .cli import main as _main


def main(argv=None) -> int:
    return _main(argv)


if __name__ == "__main__":
    raise SystemExit(main())

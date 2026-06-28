#!/usr/bin/env python3
"""Frozen esptool entrypoint for the X4 Sync Server app bundle."""

from __future__ import annotations

import sys

import esptool


def main() -> int | None:
    sys.argv[0] = "x4-flasher"
    return esptool._main()


if __name__ == "__main__":
    raise SystemExit(main())

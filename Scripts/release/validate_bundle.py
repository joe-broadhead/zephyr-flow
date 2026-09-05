#!/usr/bin/env python3
"""Read-only narrow SPM bundle preflight; no codesigning or credential access."""
import os
import pathlib
import plistlib
import re
import struct
import sys


def validate(app: pathlib.Path, version_file: pathlib.Path) -> None:
    if app.is_symlink() or not app.is_dir():
        raise ValueError("app must be a non-symlink directory")
    version = version_file.read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("invalid source version")
    executable = app / "Contents/MacOS/ZephyrFlow"
    macho = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for root, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            path = pathlib.Path(root) / name
            if path.is_symlink():
                raise ValueError("symlink in app; unsupported signing layout")
            if path.is_dir():
                continue
            if not path.is_file():
                raise ValueError("non-regular app entry")
            with path.open("rb") as stream:
                magic = stream.read(4)
            if path != executable and (magic in macho or os.access(path, os.X_OK)):
                raise ValueError("nested executable code needs explicit signing review")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for key, expected in {"CFBundleIdentifier": "dev.zephyrflow.app", "CFBundleExecutable": "ZephyrFlow",
                          "CFBundleShortVersionString": version, "CFBundleVersion": version}.items():
        if info.get(key) != expected:
            raise ValueError("bundle metadata mismatch: " + key)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("main executable missing")
    with executable.open("rb") as stream:
        header = stream.read(32)
        if len(header) != 32:
            raise ValueError("main executable header is incomplete")
        magic, cpu, _, filetype, *_ = struct.unpack("<8I", header)
        if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 2:
            raise ValueError("only a thin arm64 Mach-O executable is supported")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: validate_bundle.py APP VERSION_FILE")
        validate(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print("BUNDLE PREFLIGHT FAILED: " + str(error), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Replace constants on cell output connections with dummy wires.

Yosys refuses to flatten a module instance when an output port is connected
directly to constant bits. In RTL this pattern means those output bits are
discarded. This sanitizer preserves that behavior by rewiring only output/inout
port constant fragments to fresh, otherwise-unused wires.
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path


CONST_RE = re.compile(r"(?<![A-Za-z0-9_$\\])([0-9]+)'[01xzXZ?]+")


def module_name(line: str) -> str | None:
    if not line.startswith("module "):
        return None
    parts = line.split()
    return parts[1] if len(parts) >= 2 else None


def wire_port(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped.startswith("wire "):
        return None

    tokens = stripped.split()
    direction = None
    for token in tokens:
        if token in {"input", "output", "inout"}:
            direction = token
            break

    if direction is None:
        return None

    name = tokens[-1]
    if not name.startswith("\\"):
        return None
    return name, direction


def cell_type(line: str) -> str | None:
    stripped = line.strip()
    if not stripped.startswith("cell "):
        return None
    parts = stripped.split(maxsplit=2)
    return parts[1] if len(parts) >= 2 else None


def cell_connect(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped.startswith("connect "):
        return None
    parts = stripped.split(maxsplit=2)
    if len(parts) != 3:
        return None
    return parts[1], parts[2]


def collect_port_dirs(path: Path) -> dict[str, dict[str, str]]:
    port_dirs: dict[str, dict[str, str]] = defaultdict(dict)
    current_module = None

    with path.open() as f:
        for line in f:
            mod = module_name(line)
            if mod is not None:
                current_module = mod
                continue
            if line.startswith("end"):
                current_module = None
                continue
            if current_module is None:
                continue

            port = wire_port(line)
            if port is not None:
                name, direction = port
                port_dirs[current_module][name] = direction

    return port_dirs


def collect_dummy_widths(
    path: Path, port_dirs: dict[str, dict[str, str]]
) -> dict[str, list[int]]:
    dummy_widths: dict[str, list[int]] = defaultdict(list)
    current_module = None
    current_cell_type = None

    with path.open() as f:
        for line in f:
            mod = module_name(line)
            if mod is not None:
                current_module = mod
                current_cell_type = None
                continue
            if line.startswith("end"):
                current_module = None
                current_cell_type = None
                continue
            if current_module is None:
                continue

            ctype = cell_type(line)
            if ctype is not None:
                current_cell_type = ctype
                continue
            if line.startswith("  end"):
                current_cell_type = None
                continue
            if current_cell_type is None:
                continue

            conn = cell_connect(line)
            if conn is None:
                continue
            port, expr = conn
            if port_dirs.get(current_cell_type, {}).get(port) not in {"output", "inout"}:
                continue

            for match in CONST_RE.finditer(expr):
                dummy_widths[current_module].append(int(match.group(1)))

    return dummy_widths


def rewrite(
    src: Path,
    dst: Path,
    port_dirs: dict[str, dict[str, str]],
    dummy_widths: dict[str, list[int]],
) -> int:
    dummy_indices: dict[str, int] = defaultdict(int)
    total = 0
    current_module = None
    current_cell_type = None

    with src.open() as f, dst.open("w") as out:
        for line in f:
            mod = module_name(line)
            if mod is not None:
                current_module = mod
                current_cell_type = None
                out.write(line)
                for index, width in enumerate(dummy_widths.get(mod, [])):
                    if width == 1:
                        out.write(f"  wire \\__constout_dummy_{index}\n")
                    else:
                        out.write(f"  wire width {width} \\__constout_dummy_{index}\n")
                continue

            if line.startswith("end"):
                current_module = None
                current_cell_type = None
                out.write(line)
                continue

            if current_module is not None:
                ctype = cell_type(line)
                if ctype is not None:
                    current_cell_type = ctype
                    out.write(line)
                    continue
                if line.startswith("  end"):
                    current_cell_type = None
                    out.write(line)
                    continue

                conn = cell_connect(line)
                if current_cell_type is not None and conn is not None:
                    port, expr = conn
                    if port_dirs.get(current_cell_type, {}).get(port) in {"output", "inout"}:

                        def repl(match: re.Match[str]) -> str:
                            nonlocal total
                            index = dummy_indices[current_module]
                            dummy_indices[current_module] += 1
                            total += 1
                            return f"\\__constout_dummy_{index}"

                        line = CONST_RE.sub(repl, line)

            out.write(line)

    return total


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: sanitize_rtlil_const_outputs.py INPUT.il OUTPUT.il",
            file=sys.stderr,
        )
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    port_dirs = collect_port_dirs(src)
    dummy_widths = collect_dummy_widths(src, port_dirs)
    total = rewrite(src, dst, port_dirs, dummy_widths)
    print(f"rewired {total} output constant fragment(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

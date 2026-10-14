#!/usr/bin/env python3
"""Offline check of delivered source size and Solidity import availability."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PREFIXES = {
    "v4-core/": "lib/v4-core/",
    "forge-std/": "lib/forge-std/src/",
    "@openzeppelin/contracts/": "lib/openzeppelin-contracts/contracts/",
    "solmate/": "lib/solmate/",
}
files = [ROOT / name for name in ("foundry.toml", ".gitignore", "README.md", "LICENSE", "dependencies.lock.json")]
for folder in ("src", "test", "lib", "docs", "tools"):
    files += [p for p in (ROOT / folder).rglob("*") if p.is_file() and "scratch" not in p.parts and "__pycache__" not in p.parts]
for path in files:
    if path.suffix != ".sol":
        continue
    for name in re.findall(r'import\s+(?:[^;]*?\sfrom\s+)?["\']([^"\']+)["\']\s*;', path.read_text()):
        if name.startswith("."):
            dependency = path.parent / name
        else:
            prefix = next((p for p in PREFIXES if name.startswith(p)), None)
            assert prefix, f"Unmapped import: {path}: {name}"
            dependency = ROOT / PREFIXES[prefix] / name[len(prefix):]
        assert dependency.is_file(), f"Missing vendored import: {path}: {name}"
size = sum(p.stat().st_size for p in files)
assert size < 8 * 1024 * 1024, f"Source bundle exceeds 8 MiB: {size} bytes"
assert all(p.suffix not in {".pdf", ".gz", ".zip", ".tgz"} for p in files), "Unexpected archive in source bundle"
print(f"{len(files)} source/license/documentation files, {size:,} bytes; imports resolve offline; below 8 MiB.")

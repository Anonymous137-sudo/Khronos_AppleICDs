#!/usr/bin/env python3
"""Verify the upstream Mesa/KosmicKrisp inputs AVK143 reuses directly."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


SOURCE_INPUTS = (
    "src/vulkan/runtime/meson.build",
    "src/compiler/spirv/spirv_to_nir.c",
    "src/compiler/nir/meson.build",
    "src/kosmickrisp/vulkan/kk_device.c",
    "src/kosmickrisp/vulkan/kk_cmd_buffer.c",
    "src/kosmickrisp/compiler/nir_to_msl.c",
    "src/kosmickrisp/bridge/meson.build",
)

BUILD_INPUTS = (
    "src/kosmickrisp/vulkan/libkk.a",
    "src/kosmickrisp/bridge/libmtl_bridge.a",
    "src/kosmickrisp/vulkan/kk_entrypoints.c",
    "src/kosmickrisp/vulkan/kk_entrypoints.h",
    "src/kosmickrisp/libkk/libkk_shaders.c",
    "src/kosmickrisp/libkk/libkk_shaders.h",
)

KK_REQUIRED_SYMBOLS = ("_kk_instance_entrypoints", "_kk_device_entrypoints")


def path_status(root: Path, inputs: tuple[str, ...]) -> dict[str, bool]:
    return {entry: (root / entry).is_file() for entry in inputs}


def archive_symbol_status(archive: Path) -> dict[str, bool]:
    if not archive.is_file():
        return {symbol: False for symbol in KK_REQUIRED_SYMBOLS}

    try:
        output = subprocess.run(
            ["nm", "-gU", str(archive)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout
    except OSError:
        return {symbol: False for symbol in KK_REQUIRED_SYMBOLS}

    return {symbol: symbol in output for symbol in KK_REQUIRED_SYMBOLS}


def sha256_status(root: Path, inputs: tuple[str, ...]) -> dict[str, str | None]:
    digests: dict[str, str | None] = {}
    for entry in inputs:
        path = root / entry
        if not path.is_file():
            digests[entry] = None
            continue

        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        digests[entry] = digest.hexdigest()
    return digests


def git_provenance(root: Path) -> dict[str, object]:
    try:
        revision = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        ).stdout.strip()
        status = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain=v1"], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        ).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError):
        return {"revision": None, "dirty": None, "dirty_paths": []}

    return {
        "revision": revision,
        "dirty": bool(status),
        "dirty_paths": status,
    }


def write_json(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit direct Mesa/KosmicKrisp Vulkan prerequisites for AVK143."
    )
    configured_root = os.environ.get("AVK143_MESA_ROOT")
    parser.add_argument("--mesa-root", type=Path,
                        default=Path(configured_root) if configured_root else None)
    parser.add_argument("--mesa-build-dir", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--check-artifacts", action="store_true")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--write-provenance", type=Path)
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args()

    if args.mesa_root is None:
        parser.error("--mesa-root or AVK143_MESA_ROOT is required")

    mesa_root = args.mesa_root.resolve()
    mesa_build_dir = (
        args.mesa_build_dir.resolve()
        if args.mesa_build_dir
        else mesa_root / "build-avk143-kosmickrisp-arm64"
    )
    source_status = path_status(mesa_root, SOURCE_INPUTS)
    artifact_status = path_status(mesa_build_dir, BUILD_INPUTS)
    symbol_status = archive_symbol_status(
        mesa_build_dir / "src/kosmickrisp/vulkan/libkk.a"
    )
    repository = git_provenance(mesa_root)

    report = {
        "project": "AVK143",
        "mesa_root": str(mesa_root),
        "mesa_build_dir": str(mesa_build_dir),
        "source_inputs": source_status,
        "build_inputs": artifact_status,
        "kk_symbols": symbol_status,
        "artifact_sha256": sha256_status(mesa_build_dir, BUILD_INPUTS),
        "repository": repository,
    }
    if args.write_provenance:
        write_json(args.write_provenance, report)
    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(
            "AVK143 Mesa Vulkan inventory: "
            f"{sum(source_status.values())}/{len(source_status)} source inputs, "
            f"{sum(artifact_status.values())}/{len(artifact_status)} build inputs, "
            f"{sum(symbol_status.values())}/{len(symbol_status)} libkk symbols"
        )
        print(
            "  Mesa revision: "
            f"{repository['revision'] or 'unavailable'} "
            f"({'dirty' if repository['dirty'] else 'clean'})"
        )
        for section, values in (
            ("source", source_status),
            ("artifact", artifact_status),
            ("symbol", symbol_status),
        ):
            for name, present in values.items():
                print(f"  {'[x]' if present else '[ ]'} {section}: {name}")

    if args.check and not all(source_status.values()):
        return 1
    if args.check_artifacts and (
        not all(artifact_status.values()) or not all(symbol_status.values())
    ):
        return 1
    if args.require_clean and repository["dirty"] is not False:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

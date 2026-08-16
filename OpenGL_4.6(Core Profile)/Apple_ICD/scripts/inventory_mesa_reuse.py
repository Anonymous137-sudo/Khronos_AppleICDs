#!/usr/bin/env python3
"""Audit Mesa components that can accelerate AO46's Metal Gallium backend."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


SOURCE_SUFFIXES = {".c", ".h", ".m", ".mm", ".cl"}
NATIVE_AGX_MARKERS = ("drm_asahi", "drmIoctl", "AGX_BO_EXEC", "agx_batch")


def required_artifacts(mesa_root: Path) -> dict[str, Path]:
    return {
        "KosmicKrisp Vulkan feature archive": (
            mesa_root / "build-ao46-kosmickrisp-arm64/src/kosmickrisp/vulkan/libkk.a"
        ),
        "Asahi Gallium feature archive": (
            mesa_root / "build-ao46-asahi-arm64/src/gallium/drivers/asahi/libasahi.a"
        ),
    }


@dataclass(frozen=True)
class Candidate:
    key: str
    mode: str
    paths: tuple[str, ...]
    destination: str
    purpose: str
    rule: str


CANDIDATES = (
    Candidate(
        "kk-nir-to-msl",
        "direct",
        ("src/kosmickrisp/compiler",),
        "AO46MesaMSLComputePipeline.c; AO46MesaMSLRenderPipeline.c",
        "Mesa NIR-to-MSL compilation and reflection.",
        "Link the upstream compiler; do not create a second shader compiler.",
    ),
    Candidate(
        "kk-metal-bridge",
        "direct",
        ("src/kosmickrisp/bridge",),
        "AO46AGXMetalAdapter",
        "Public Metal device, resources, command buffers, encoders, argument tables, residency, and synchronization.",
        "Extend the bridge wrapper first; do not duplicate Metal object lifetime code.",
    ),
    Candidate(
        "kk-libkk-and-poly",
        "direct",
        ("src/kosmickrisp/libkk", "src/poly"),
        "AO46MesaPolyTessellation.c; AO46MesaPolyKernelExecutor.c",
        "Mesa Poly geometry and tessellation lowering plus generated helper kernels.",
        "Reuse the upstream kernels and lowering; only schedule them through Gallium/Metal.",
    ),
    Candidate(
        "kk-image-and-format",
        "port",
        (
            "src/kosmickrisp/vulkan/kk_image.c",
            "src/kosmickrisp/vulkan/kk_image_view.c",
            "src/kosmickrisp/vulkan/kk_buffer_view.c",
            "src/kosmickrisp/vulkan/kk_format.c",
        ),
        "AO46MetalGalliumScreen.c; AO46AGXMetalAdapter",
        "General images, views, texel buffers, and format/usage validation.",
        "Port algorithms behind pipe_resource and pipe_sampler_view; retain no Vulkan object ABI.",
    ),
    Candidate(
        "kk-descriptors-and-nir",
        "port",
        (
            "src/kosmickrisp/vulkan/kk_descriptor_set.c",
            "src/kosmickrisp/vulkan/kk_descriptor_set_layout.c",
            "src/kosmickrisp/vulkan/kk_nir_lower_descriptors.c",
            "src/kosmickrisp/vulkan/kk_nir_lower_textures.c",
            "src/kosmickrisp/vulkan/kk_nir_lower_vbo.c",
        ),
        "AO46MesaMSL*Pipeline.c; AO46MetalGalliumScreen.c",
        "General sampler, image, UBO, SSBO, texel-buffer, and vertex-input binding contracts.",
        "Translate descriptor concepts to Gallium state and KK argument tables; do not import Vulkan descriptors.",
    ),
    Candidate(
        "kk-commands-and-sync",
        "port",
        (
            "src/kosmickrisp/vulkan/kk_cmd_buffer.c",
            "src/kosmickrisp/vulkan/kk_cmd_clear.c",
            "src/kosmickrisp/vulkan/kk_cmd_copy.c",
            "src/kosmickrisp/vulkan/kk_cmd_dispatch.c",
            "src/kosmickrisp/vulkan/kk_cmd_draw.c",
            "src/kosmickrisp/vulkan/kk_queue.c",
            "src/kosmickrisp/vulkan/kk_sync.c",
            "src/kosmickrisp/vulkan/kk_event.c",
        ),
        "AO46AGXMetalAdapter; AO46MetalGalliumScreen.c",
        "Batched command, queue ordering, fence, event, and retained-resource lifecycle patterns.",
        "Port behavior to AO46MetalSubmission; retain no Vulkan queue or command-buffer ABI.",
    ),
    Candidate(
        "kk-queries-and-wsi",
        "port",
        (
            "src/kosmickrisp/vulkan/kk_query_pool.c",
            "src/kosmickrisp/vulkan/kk_query_table.c",
            "src/kosmickrisp/vulkan/kk_wsi.c",
        ),
        "AO46MetalGalliumScreen.c; AO46MesaBridge.c",
        "Query retirement and drawable/presentation lifetime behavior.",
        "Port the lifecycle rules, then validate them with Gallium fences and CGL drawables.",
    ),
    Candidate(
        "asahi-nir-lowering",
        "port",
        (
            "src/gallium/drivers/asahi/agx_nir_lower_bindings.c",
            "src/gallium/drivers/asahi/agx_nir_lower_point_size.c",
            "src/gallium/drivers/asahi/agx_nir_lower_sysvals.c",
            "src/gallium/drivers/asahi/agx_uniforms.c",
        ),
        "AO46MesaMSL*Pipeline.c",
        "Gallium-facing shader interface, sysval, uniform, and binding behavior.",
        "Isolate each lowering from AGX headers and retarget it to NIR-to-MSL reflection.",
    ),
    Candidate(
        "asahi-state-and-pipe",
        "reference",
        (
            "src/gallium/drivers/asahi/agx_state.c",
            "src/gallium/drivers/asahi/agx_pipe.c",
        ),
        "AO46MetalGalliumScreen.c",
        "Gallium callback coverage, state-object validation, and capability audit reference.",
        "Use as a feature checklist and port only isolated state algorithms; AGX state packets stay out.",
    ),
    Candidate(
        "asahi-blit-streamout-query",
        "reference",
        (
            "src/gallium/drivers/asahi/agx_blit.c",
            "src/gallium/drivers/asahi/agx_streamout.c",
            "src/gallium/drivers/asahi/agx_query.c",
        ),
        "AO46MetalGalliumScreen.c; AO46AGXMetalAdapter",
        "Feature algorithms for blits, transform feedback, and query state.",
        "Port behavior with Metal compute/render work; do not retain agx_context or agx_batch dependencies.",
    ),
    Candidate(
        "asahi-execution-core",
        "exclude",
        (
            "src/gallium/drivers/asahi/agx_batch.c",
            "src/gallium/drivers/asahi/agx_sync.c",
            "src/gallium/drivers/asahi/agx_fence.c",
            "src/asahi/compiler",
            "src/asahi/lib",
            "src/asahi/libagx",
            "src/asahi/layout",
        ),
        "Not part of the Metal backend",
        "AGX binaries, BO/VM ownership, command streams, DRM submission, and DRM synchronization.",
        "Reference only. These paths cannot be linked or adapted as a Metal winsys.",
    ),
)


def source_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path] if path.suffix in SOURCE_SUFFIXES else []
    if not path.is_dir():
        return []
    return sorted(item for item in path.rglob("*")
                  if item.is_file() and item.suffix in SOURCE_SUFFIXES)


def inspect_candidate(candidate: Candidate, mesa_root: Path) -> dict[str, object]:
    resolved_paths = [mesa_root / relative for relative in candidate.paths]
    files = [file for path in resolved_paths for file in source_files(path)]
    markers: set[str] = set()

    for file in files:
        try:
            text = file.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        markers.update(marker for marker in NATIVE_AGX_MARKERS if marker in text)

    missing = [relative for relative, path in zip(candidate.paths, resolved_paths)
               if not path.exists()]
    return {
        **asdict(candidate),
        "file_count": len(files),
        "native_agx_markers": sorted(markers),
        "missing_paths": missing,
    }


def markdown(records: list[dict[str, object]], mesa_root: Path) -> str:
    lines = [
        "# Mesa Metal Gallium Reuse Inventory",
        "",
        "Generated by `scripts/inventory_mesa_reuse.py`. This is a source",
        "selection map, not a code-copy mechanism. Preserve upstream SPDX headers",
        "and isolate each port behind the AO46 Gallium/Metal boundary.",
        "",
        f"Mesa root: `{mesa_root}`",
        "",
        "| Candidate | Mode | Source files | Native AGX/DRM markers | AO46 destination |",
        "| --- | --- | ---: | --- | --- |",
    ]
    for record in records:
        markers = ", ".join(record["native_agx_markers"]) or "none"
        lines.append(
            f"| `{record['key']}` | `{record['mode']}` | {record['file_count']} | "
            f"{markers} | {record['destination']} |"
        )

    lines.extend(["", "## Candidate Rules", ""])
    for record in records:
        paths = ", ".join(f"`{path}`" for path in record["paths"])
        lines.extend([
            f"### `{record['key']}`",
            f"- Sources: {paths}",
            f"- Purpose: {record['purpose']}",
            f"- Rule: {record['rule']}",
            "",
        ])
    return "\n".join(lines)


def main() -> int:
    script_root = Path(__file__).resolve().parent
    default_mesa_root = script_root.parent.parent / "mesa"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mesa-root", type=Path, default=default_mesa_root)
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true",
                        help="fail when an inventoried upstream path is absent")
    parser.add_argument("--check-artifacts", action="store_true",
                        help="also require the configured KK and Asahi archives")
    args = parser.parse_args()

    mesa_root = args.mesa_root.resolve()
    records = [inspect_candidate(candidate, mesa_root) for candidate in CANDIDATES]
    missing = [
        f"{record['key']}: {path}"
        for record in records for path in record["missing_paths"]
    ]

    missing_artifacts = [
        f"{label}: {path}"
        for label, path in required_artifacts(mesa_root).items()
        if not path.is_file()
    ] if args.check_artifacts else []

    if args.check:
        if missing:
            print("Mesa reuse inventory has missing upstream paths:", file=sys.stderr)
            print("\n".join(missing), file=sys.stderr)
            return 1
        if missing_artifacts:
            print("Mesa reuse inventory has missing porting artifacts:", file=sys.stderr)
            print("\n".join(missing_artifacts), file=sys.stderr)
            return 1
        print(f"Mesa reuse inventory verified {len(records)} candidates under {mesa_root}")
        return 0

    content = (markdown(records, mesa_root) if args.format == "markdown"
               else json.dumps(records, indent=2, sort_keys=True) + "\n")
    if args.output:
        args.output.write_text(content, encoding="utf-8")
    else:
        print(content, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# Vulkan CTS-Qualified Engineering Release

**Release ID:** `vulkan-api-sdk-1.4.354-cts-qualified-1.4.3.2-20260821`

**Release date:** 2026-08-21

**Target:** Apple Silicon macOS, Mesa KosmicKrisp ICD through the standard
Khronos loader/ICD ABI

**Runtime API/header package:** Vulkan API SDK 1.4.354

**Qualification suite:** `vulkan-cts-1.4.3.2`

## Scope and Status

This is an engineering qualification release, not a Khronos conformant-product
release. The ICD intentionally reports:

```text
VkConformanceVersion = { 0, 0, 0, 0 }
```

The release label contains `1.4.3.2` only because that is the CTS suite
revision used to produce the attached evidence. A nonzero Vulkan conformance
version is reserved for an implementation accepted through Khronos's official
conformance process.

## CTS Evidence

The local non-experimental `dEQP-VK` inventory contains **2,858,036** cases.
The campaign was run in resumable, capability-gated waves against the staged
KosmicKrisp ICD. The final remaining wave was executed on 2026-08-21 with eight
workers:

| Final-wave result | Count |
| --- | ---: |
| Terminal results | 881,906 |
| Pass | 257,266 |
| NotSupported | 624,638 |
| Fail | 0 |
| QualityWarning | 2 |

The two retained quality warnings are:

```text
dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_2
dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_4
```

They record a Vulkan-permitted, nonpreferred early-fragment sample-mask
ordering. The driver truthfully exposes the corresponding physical-device
properties instead of claiming a stricter ordering that the public Metal
execution path cannot guarantee. They are retained as `QualityWarning` in the
raw QPA files and are not relabeled as passes.

The release ledger also records the deliberately unresolved
`dEQP-VK.api.driver_properties.conformance_version` self-test. It expects an
official nonzero `VkConformanceVersion`; this driver returns zero until it is
certified. Historical pre-gating failures are retained in the evidence set but
are not counted as current capability claims: affected Vulkan Memory Model
features are now reported unsupported rather than advertised incorrectly.

## Runtime Provenance

| Source component | Pinned revision |
| --- | --- |
| Mesa/KosmicKrisp | `4bdd6173e129e893b43ed4e11c8da3c853e48b53` |
| MoltenVK vendor reference | `f9a1e964bf2e247c97def4f77636346c0fe0ded2` |

| Artifact | SHA-256 |
| --- | --- |
| `libvulkan_kosmickrisp.dylib` | `b0e3e6f20c216f0ed34dbbad94e0d2d8e09d80fa481716a777f20ceb21f8e1ec` |
| `kosmickrisp_mesa_icd.aarch64.json` | `c11b9141509859419c70c6dd6884c241782bf7daf31bdcdd484a957f3a6214bc` |

The local shader cache was measured as SHA-256
`cb7177f28614875d314d242cf91f8d2a85ca308bd1f3e83ee784941056e2eea9`.
It is intentionally not published as a portability artifact: it is
machine-local cache data, not driver source, ABI, or CTS evidence.

The committed CTS inventory catalog (`dEQP-VK-cases.xml`) has SHA-256
`c99040eb95c89f9ba959fd4bceaf17990ff7e0325f902748bf6f5188129cd147`.
The small historical `TestResults.qpa` checksum is
`ffba805f25da4efd179d517a539fc52dc84a9b479be0a900498fb7aa67ce24ab`; it is
included in the evidence asset rather than committed as a standalone Git blob.

## Delivered Assets

The matching GitHub release contains checksummed assets for:

- the signed/staged macOS arm64 ICD runtime and JSON manifest;
- the source-bootstrap `VulkanICD_KHRInstaller.pkg`;
- final-wave raw QPA files, case lists, worker exit codes, and standard output;
- an evidence bundle with the release ledger and semantic-delta record.

| Release asset | SHA-256 |
| --- | --- |
| `VulkanICD_KHRInstaller-1.4.354-cts-qualified-1.4.3.2-20260821.pkg` | `f3f24b90be1b9bd8fd20fa1dffc55ea231e5d6c1fdc6f0bdfec4792143233ad8` |
| `avk143-vulkan-api-sdk-1.4.354-macos-arm64-runtime.tar.gz` | `53123fa05a47d10776236b0c08fa36e0fe6b1580edbabe8afa672e8788047633` |
| `avk143-vulkan-cts-1.4.3.2-final-881906-qpa.tar.gz` | `e552261f2ef15f0d792d14b39f81d3125c73be51008140079b2a72127ce0d5db` |
| `avk143-vulkan-cts-qualified-1.4.3.2-20260821-evidence.tar.gz` | `71c63b4ecee8ea441d4776ee75ecde527874596c71197fc981b94c5a38e4572c` |
| `SHA256SUMS.txt` | `f8eeed94aa2c750580abbbff3d06eed0437cf6f55f7407620de7ea86ba694342` |

Run the release assets only with the recorded macOS/Apple Silicon environment
and standard Vulkan loader contract. The QPA files are evidence for this
engineering release; they are not a Khronos certificate.

## Follow-On Work

- Reproduce the campaign on clean, independent hosts and toolchains.
- Resolve the two quality warnings only if Metal exposes a correct fixed
  sample-mask ordering or an equivalent validated implementation.
- Continue hardware ray-tracing research separately from this release.
- Resume AO46 Metal Gallium work; the temporary OpenGL implementation freeze is
  lifted by this release.

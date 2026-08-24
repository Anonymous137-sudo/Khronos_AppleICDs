# Engineering Releases

This directory contains source-controlled release metadata for the AVK143
Vulkan ICD. Large, machine-produced QPA logs and runtime archives are attached
to the matching GitHub release instead of being committed as Git objects.

The release label `cts-qualified-1.4.3.2-20260821` identifies the Vulkan CTS
suite revision and qualification campaign. It is not a `VkConformanceVersion`,
does not imply Khronos certification, and must not be used to market the ICD as
a conformant Vulkan implementation.

Each release record includes the exact runtime binary and manifest hashes,
source revisions, capability-policy notes, semantic delta, CTS result ledger,
and the checksums for published artifacts.

## Version 2 draft

`V2_CTS_1.4.6.2_DRAFT_20260822.md` and its machine-readable JSON manifest
record the current Mesa-main synchronization, the correction of the old
CTS-driven extension-suppression policy, all focused CTS 1.4.6.2 evidence, and
the unresolved Vulkan Memory Model blocker. Version 2 is not yet qualified:
the full four-phase mustpass campaign remains gated until `info` and
`memory_model` pass honestly.

## Developer prerelease

`PRE_RELEASE_CTS_1.4.6.2_20260824.md` is the current machine-neutral Vulkan
ICD 1.4.354 developer-preview record. It names the synchronized Mesa revisions,
the complete runtime package contents, the focused CTS 1.4.6.2 results, and the
six unresolved memory-model failures. It is explicitly not a conformance or
certification claim.

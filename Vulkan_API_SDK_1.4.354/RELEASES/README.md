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

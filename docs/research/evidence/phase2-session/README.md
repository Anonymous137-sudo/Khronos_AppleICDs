# Phase 2 Research Evidence

This directory preserves the textual evidence captured during the Phase 2
macOS AGX/UABI research session. It is tracked separately from build output
so the observations used by the architecture documents remain reviewable and
reproducible from Git history.

Included material:

- direct trace transcripts and controlled workload deltas;
- derived sidecar-layout and pointer-layout reports;
- IOKit/private-winsys inventory snapshots and ownership maps;
- command-storage, resource-record, queue, and shader-contract observations.

`SHA256SUMS` records the digest of every captured evidence file. The files are
an archived observation set, not a supported runtime ABI or an implementation
contract.

Intentionally excluded:

- CMake build trees, generated compiler probes, and test runner state;
- Python bytecode, editor metadata, and local virtual environments;
- extracted Apple binaries or decompiled implementation output.

The original machine-local capture directory remains ignored at
`OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/phase2-session`.

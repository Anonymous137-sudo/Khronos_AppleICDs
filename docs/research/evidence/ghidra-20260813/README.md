# Ghidra Research Evidence (2026-08-13)

This archive preserves the raw textual outputs recovered from the AO46 Ghidra
research sessions. Files were copied byte-for-byte from their temporary-source
locations so the C-style decompiler reports, call graphs, policy analyses, and
`analyzeHeadless` logs can be reviewed alongside the project code.

Included material:

- AGXMetalG16X, AGXG16X kernel, compiler, IOGPU, and MTL compiler reports;
- Ghidra decompiler and graph-export text output;
- Ghidra headless-analysis logs;
- the related `/private/var` resource and private-winsys trace logs.

`SOURCE_PATHS.tsv` maps each archived file to its original temporary path.
`SHA256SUMS` records the digest of every archived evidence file and metadata
file, excluding the checksum manifest itself.

This is an archived observation set. It is not a stable ABI specification and
must not be treated as an implementation contract.

Excluded material:

- executable images, kernel images, dyld extracts, and other binary inputs;
- Ghidra database/index directories and local project locks;
- CMake build output, Python caches, and editor metadata.

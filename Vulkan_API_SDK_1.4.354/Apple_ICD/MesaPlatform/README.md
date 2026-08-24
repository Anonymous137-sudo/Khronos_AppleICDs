# Mesa platform layer

KosmicKrisp is not a standalone collection of `kk_*.c` files. It consumes
Mesa's Vulkan runtime and WSI, NIR compiler, format helpers, synchronization,
and common utilities. Those remain canonical in the sibling Mesa submodule and
are selected by Mesa's Meson build. `AVK143MesaPlatformSources` records the
relevant build roots for source navigation and dependency auditing.

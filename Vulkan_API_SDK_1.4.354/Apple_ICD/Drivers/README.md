# Driver sources

AVK143's Vulkan implementation is Mesa's KosmicKrisp driver. The canonical
source stays in the sibling `../mesa` submodule so Mesa runtime, NIR, compiler,
WSI, and utility code always advance as one coherent revision. The
`KosmicKrisp` integration directory inventories those sources and exposes the
assembly target without duplicating them here.

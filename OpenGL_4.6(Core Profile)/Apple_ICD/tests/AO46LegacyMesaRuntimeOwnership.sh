#!/bin/sh

set -eu

core=${1:?AO46Core dylib path is required}

dependencies=$(otool -L "$core")
if printf '%s\n' "$dependencies" |
   grep -Eq 'libAO46(MTLGallium|MesaMetalBackend)\.dylib'; then
    echo "AO46Core must not send legacy Mesa NIR through a backend dylib" >&2
    exit 1
fi
singleton_count=$(nm -m "$core" 2>/dev/null |
    grep -c '_glsl_type_builtin_mat2x3$' || true)
if [ "$singleton_count" -ne 1 ]; then
    echo "AO46Core must own exactly one Mesa GLSL type singleton set" >&2
    exit 1
fi

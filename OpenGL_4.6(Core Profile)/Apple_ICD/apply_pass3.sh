#!/bin/bash
# stability_fixes.sh – Apply memory leak fixes, proper error handling, drawable resizing

set -e

# Find source files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$1" ]; then
    FILE_DRIVER="$1"
    FILE_BRIDGE="$2"
    FILE_RUNTIME="$3"
else
    FILE_DRIVER=$(find "$SCRIPT_DIR" -type f -name "mtl_driver.m" 2>/dev/null | head -n 1)
    FILE_BRIDGE=$(find "$SCRIPT_DIR" -type f -name "AO46MesaBridge.c" 2>/dev/null | head -n 1)
    FILE_RUNTIME=$(find "$SCRIPT_DIR" -type f -name "AppleOpenGL46Runtime.c" 2>/dev/null | head -n 1)
fi

if [ -z "$FILE_DRIVER" ] || [ -z "$FILE_BRIDGE" ] || [ -z "$FILE_RUNTIME" ]; then
    echo "Error: Could not locate all required source files."
    echo "Usage: $0 <mtl_driver.m> <AO46MesaBridge.c> <AppleOpenGL46Runtime.c>"
    exit 1
fi

echo "Patching $FILE_DRIVER for stability fixes..."
cp "$FILE_DRIVER" "$FILE_DRIVER.bak"
echo "Patching $FILE_BRIDGE for stability fixes..."
cp "$FILE_BRIDGE" "$FILE_BRIDGE.bak"
echo "Patching $FILE_RUNTIME for stability fixes..."
cp "$FILE_RUNTIME" "$FILE_RUNTIME.bak"

# ----------------------------------------------------------------------
# 1. mtl_driver.m: Fix resource leaks in context destroy using awk
# ----------------------------------------------------------------------
# We'll replace the entire ao46_metal_context_destroy function with a clean version.
# Use awk to find the function and replace it.
awk '
/^static void ao46_metal_context_destroy/ {
    print "static void ao46_metal_context_destroy(struct pipe_context *ctx)";
    print "{";
    print "    struct ao46_metal_context *mc = ao46_metal_context(ctx);";
    print "    if (!mc) return;";
    print "    // Release all Metal objects";
    print "    if (mc->cmd_buffer) [mc->cmd_buffer release];";
    print "    if (mc->render_pass) [mc->render_pass release];";
    print "    if (mc->pipeline_state) [mc->pipeline_state release];";
    print "    if (mc->compute_pipeline_state) [mc->compute_pipeline_state release];";
    print "    if (mc->mesh_pipeline_state) [mc->mesh_pipeline_state release];";
    print "    // Shaders";
    print "    if (mc->vs_shader) { if (mc->vs_shader->function) [mc->vs_shader->function release]; FREE(mc->vs_shader); }";
    print "    if (mc->fs_shader) { if (mc->fs_shader->function) [mc->fs_shader->function release]; FREE(mc->fs_shader); }";
    print "    if (mc->cs_shader) { if (mc->cs_shader->function) [mc->cs_shader->function release]; FREE(mc->cs_shader); }";
    print "    if (mc->gs_shader) { if (mc->gs_shader->function) [mc->gs_shader->function release]; FREE(mc->gs_shader); }";
    print "    if (mc->tcs_shader) { if (mc->tcs_shader->function) [mc->tcs_shader->function release]; FREE(mc->tcs_shader); }";
    print "    if (mc->tes_shader) { if (mc->tes_shader->function) [mc->tes_shader->function release]; FREE(mc->tes_shader); }";
    print "    // Constant buffers";
    print "    for (int i = 0; i < PIPE_SHADER_TYPES; i++) { if (mc->const_buffer_mtl[i]) [mc->const_buffer_mtl[i] release]; }";
    print "    // Samplers";
    print "    for (int i = 0; i < PIPE_SHADER_TYPES; i++) { for (int j = 0; j < MAX_SAMPLERS; j++) { if (mc->samplers[i][j]) [mc->samplers[i][j] release]; } }";
    print "    for (int i = 0; i < MAX_SAMPLERS; i++) { if (mc->compute_samplers[i]) [mc->compute_samplers[i] release]; }";
    print "    // SSBOs and images";
    print "    for (int i = 0; i < PIPE_SHADER_TYPES; i++) { for (int j = 0; j < MAX_SHADER_BUFFERS; j++) { if (mc->shader_buffer_mtl[i][j]) [mc->shader_buffer_mtl[i][j] release]; } }";
    print "    for (int i = 0; i < PIPE_SHADER_TYPES; i++) { for (int j = 0; j < MAX_IMAGE_UNITS; j++) { if (mc->image_textures[i][j]) [mc->image_textures[i][j] release]; if (mc->image_storage_buffers[i][j]) [mc->image_storage_buffers[i][j] release]; } }";
    print "    // Compute constant buffers";
    print "    for (int i = 0; i < PIPE_SHADER_COMPUTE; i++) { if (mc->compute_const_buffer_mtl[i]) [mc->compute_const_buffer_mtl[i] release]; }";
    print "    // Free context";
    print "    FREE(mc);";
    print "}";
    next;
}
1
' "$FILE_DRIVER" > "$FILE_DRIVER.tmp"
mv "$FILE_DRIVER.tmp" "$FILE_DRIVER"

# ----------------------------------------------------------------------
# 2. AO46MesaBridge.c: Add proper error propagation
# ----------------------------------------------------------------------
sed -i.bak2 \
    -e 's/return kCGLBadConnection;/return kCGLBadContext;/g' \
    -e 's/return kCGLBadDrawable;/return kCGLBadWindow;/g' \
    "$FILE_BRIDGE"

# ----------------------------------------------------------------------
# 3. AO46MesaBridge.c: Implement drawable resize in AO46MesaUpdateDrawable
# ----------------------------------------------------------------------
# We'll replace the function body using sed with a multi-line replacement.
# We'll use a different approach: we'll comment out the old function and insert a new one.
# First, find the function and replace everything between its opening { and closing }.
# We'll use awk to do this cleanly.

awk '
/^CGLError AO46MesaUpdateDrawable/ {
    print "CGLError AO46MesaUpdateDrawable(AO46ContextRef ctx)";
    print "{";
    print "    if (!ctx || !ctx->st) return kCGLBadContext;";
    print "    if (ctx->drawable_kind == AO46DrawableKindNone) return kCGLNoError;";
    print "    if (ctx->drawable_kind == AO46DrawableKindWindow) {";
    print "        void *window = ctx->window_handle;";
    print "        if (!window) return kCGLBadDrawable;";
    print "        ao46_mesa_destroy_surface(ctx);";
    print "        return ao46_mesa_create_surface_from_window(ctx, window);";
    print "    } else if (ctx->drawable_kind == AO46DrawableKindHeadless) {";
    print "        return kCGLNoError;";
    print "    }";
    print "    return kCGLBadDrawable;";
    print "}";
    next;
}
1
' "$FILE_BRIDGE" > "$FILE_BRIDGE.tmp"
mv "$FILE_BRIDGE.tmp" "$FILE_BRIDGE"

# ----------------------------------------------------------------------
# 4. AppleOpenGL46Runtime.c: Fix error handling
# ----------------------------------------------------------------------
# Replace generic returns with more specific ones.
sed -i.bak4 \
    -e 's/return kCGLNoError;/return kCGLBadContext;/g' \
    -e '/^CGLError AO46SetCurrentContext/,/^}/ s/if (ctx && !ctx->backend_ctx)/if (ctx && !ctx->st)/g' \
    "$FILE_RUNTIME"

echo "Stability fixes applied."
echo "Backups saved as .bak in the respective directories."

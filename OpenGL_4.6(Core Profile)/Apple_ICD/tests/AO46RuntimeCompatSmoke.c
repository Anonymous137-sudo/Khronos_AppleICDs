#include "AppleOpenGL46Runtime.h"

#include <stdio.h>
#include <string.h>

static int gl_version_at_least(GLint major,
                               GLint minor,
                               GLint required_major,
                               GLint required_minor)
{
    if (major != required_major) {
        return major > required_major;
    }

    return minor >= required_minor;
}

static int gl_has_extension(const char *needle)
{
    GLint extension_count = 0;

    if (!needle || !needle[0]) {
        return 0;
    }

    glGetIntegerv(GL_NUM_EXTENSIONS, &extension_count);
    for (GLint i = 0; i < extension_count; i++) {
        const char *extension = (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)i);

        if (extension && strcmp(extension, needle) == 0) {
            return 1;
        }
    }

    return 0;
}

static int gl_has_core_or_extension(GLint major,
                                    GLint minor,
                                    GLint required_major,
                                    GLint required_minor,
                                    const char *extension)
{
    return gl_version_at_least(major, minor, required_major, required_minor) ||
           gl_has_extension(extension);
}

static int expect_no_error(const char *label, CGLError err)
{
    if (err == kCGLNoError) {
        return 0;
    }

    fprintf(stderr, "%s failed with CGLError %d\n", label, err);
    return 1;
}

static int expect_true(const char *label, int condition)
{
    if (condition) {
        return 0;
    }

    fprintf(stderr, "%s failed\n", label);
    return 1;
}

int main(void)
{
    const CGLPixelFormatAttribute attribs[] = {
        kCGLPFARendererID,
        (CGLPixelFormatAttribute)0x414F3436,
        kCGLPFADisplayMask,
        (CGLPixelFormatAttribute)0x1,
        kCGLPFAAlphaSize,
        (CGLPixelFormatAttribute)8,
        kCGLPFASampleBuffers,
        (CGLPixelFormatAttribute)1,
        kCGLPFASamples,
        (CGLPixelFormatAttribute)4,
        kCGLPFAMultisample,
        kCGLPFAAccelerated,
        kCGLPFAOffScreen,
        kCGLPFAWindow,
        kCGLPFAPBuffer,
        kCGLPFAVirtualScreenCount,
        (CGLPixelFormatAttribute)1,
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_GL3_Core,
        0
    };
    AO46RendererInfoRef rend = NULL;
    AO46PBufferRef pbuffer = NULL;
    AO46PBufferRef bound_pbuffer = NULL;
    AO46PixelFormatRef pix = NULL;
    AO46PixelFormatRef pix46 = NULL;
    AO46ContextRef ctx = NULL;
    AO46ContextRef ctx46 = NULL;
    AO46ContextRef copy_ctx = NULL;
    AO46ContextRef shared_ctx = NULL;
    AO46ContextRef independent_ctx = NULL;
    AO46ShareGroupRef ctx_group = NULL;
    AO46ShareGroupRef shared_group = NULL;
    AO46ShareGroupRef independent_group = NULL;
    GLint nrend = 0;
    GLint npix = 0;
    GLint npix46 = 0;
    GLint value = 0;
    GLint gl_major = 0;
    GLint gl_minor = 0;
    GLint screen = -1;
    GLint swap_rectangle[4] = { 10, 20, 640, 480 };
    GLint swap_rectangle_out[4] = { 0, 0, 0, 0 };
    GLint backing_size[2] = { 1280, 720 };
    GLint backing_size_out[2] = { 0, 0 };
    GLint swap_interval = 3;
    GLint format_cache_size = 32;
    GLint renderer_id = 0;
    GLint display_mask = 0;
    GLint renderer_sample_modes = 0;
    GLint alpha_bits = 0;
    GLint sample_buffers = 0;
    GLint samples = 0;
    GLint virtual_screen_count = 0;
    unsigned char offscreen_storage[64] = { 0 };
    unsigned char triangle_storage[32 * 32 * 4] = { 0 };
    GLubyte readback_pixel[4] = { 0 };
    GLubyte scissored_pixel[4] = { 0 };
    GLubyte preserved_pixel[4] = { 0 };
    GLubyte triangle_pixel[4] = { 0 };
    GLubyte indexed_triangle_pixel[4] = { 0 };
    GLubyte background_pixel[4] = { 0 };
    GLubyte textured_pixel[4] = { 0 };
    GLubyte uploaded_texture_readback[16] = { 0 };
    GLubyte aligned_texture_readback[16] = { 0 };
    GLubyte pbuffer_texture_pixel[4] = { 0 };
    GLubyte moved_triangle_center_pixel[4] = { 0 };
    GLubyte moved_triangle_corner_pixel[4] = { 0 };
    const GLubyte *gl_string = NULL;
    char gl_version_prefix[16] = { 0 };
    GLint viewport[4] = { 0, 0, 0, 0 };
    GLboolean color_mask[4] = { GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE };
    void *offscreen_ptr = NULL;
    GLsizei pbuffer_width = 0;
    GLsizei pbuffer_height = 0;
    GLenum pbuffer_target = 0;
    GLenum pbuffer_internal_format = 0;
    GLint pbuffer_mipmap = 0;
    GLenum pbuffer_face = 0;
    GLint pbuffer_level = 0;
    GLint pbuffer_screen = -1;
    GLuint vertex_shader = 0;
    GLuint fragment_shader = 0;
    GLuint program = 0;
    GLuint texture = 0;
    GLuint textured_vertex_shader = 0;
    GLuint textured_fragment_shader = 0;
    GLuint textured_program = 0;
    GLuint aligned_texture = 0;
    GLuint textured_vbo = 0;
    GLuint textured_vao = 0;
    GLuint pbuffer_texture = 0;
    GLuint vbo = 0;
    GLuint copy_vbo = 0;
    GLuint dsa_vbo = 0;
    GLuint dsa_immutable_vbo = 0;
    GLuint ebo = 0;
    GLuint vao = 0;
    GLint compile_status = 0;
    GLint textured_fragment_compile_status = 0;
    GLint link_status = 0;
    GLint validate_status = 0;
    GLint attached_shader_count = 0;
    GLint active_attribute_count = 0;
    GLint active_uniform_count = 0;
    GLint current_program = 0;
    GLint array_buffer_binding = 0;
    GLint copy_read_buffer_binding = 0;
    GLint copy_write_buffer_binding = 0;
    GLint element_array_buffer_binding = 0;
    GLint texture_binding_2d = 0;
    GLint vertex_array_binding = 0;
    GLint buffer_size = 0;
    GLint buffer_usage = 0;
    GLint active_texture = 0;
    GLint texture_width = 0;
    GLint texture_height = 0;
    GLint texture_internal_format = 0;
    GLint texture_min_filter = 0;
    GLint texture_mag_filter = 0;
    GLint pack_alignment = 0;
    GLint unpack_alignment = 0;
    GLint max_texture_units = 0;
    GLint max_vertex_attribs = 0;
    GLint attrib_location = -1;
    GLint texcoord_location = -1;
    GLint texture_uniform_location = -1;
    GLint delete_status = 0;
    int have_buffer_storage = 0;
    int have_clear_buffer_object = 0;
    int have_dsa = 0;
    int have_shader_storage = 0;
    int have_atomic_counters = 0;
    int have_texture_storage = 0;
    const CGLPixelFormatAttribute attribs46[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_6_Core,
        0
    };

    if (expect_no_error("AO46SetGlobalOption(format cache size)",
                        AO46SetGlobalOption(kCGLGOFormatCacheSize, &format_cache_size)) ||
        expect_no_error("AO46GetGlobalOption(format cache size)",
                        AO46GetGlobalOption(kCGLGOFormatCacheSize, &value)) ||
        expect_true("format cache size round-trip", value == format_cache_size)) {
        return 1;
    }

    if (expect_no_error("AO46SetOption(retain renderers)",
                        AO46SetGlobalOption(kCGLGORetainRenderers, &(GLint){ 0 })) ||
        expect_no_error("AO46GetOption(retain renderers)",
                        AO46GetGlobalOption(kCGLGORetainRenderers, &value)) ||
        expect_true("retain renderers toggle", value == 0)) {
        return 1;
    }

    if (expect_no_error("AO46QueryRendererInfo", AO46QueryRendererInfo(0, &rend, &nrend)) ||
        expect_true("exactly one renderer", nrend == 1) ||
        expect_no_error("AO46DescribeRenderer(renderer id)",
                        AO46DescribeRenderer(rend, 0, kCGLRPRendererID, &renderer_id)) ||
        expect_true("renderer id matches", renderer_id == 0x414F3436) ||
        expect_no_error("AO46DescribeRenderer(display mask)",
                        AO46DescribeRenderer(rend, 0, kCGLRPDisplayMask, &display_mask)) ||
        expect_true("renderer display mask is nonzero", display_mask != 0) ||
        expect_no_error("AO46DescribeRenderer(major GL version)",
                        AO46DescribeRenderer(rend, 0, kCGLRPMajorGLVersion, &value)) ||
        expect_true("renderer advertises GL4-class support", value == 4) ||
        expect_no_error("AO46DescribeRenderer(max sample buffers)",
                        AO46DescribeRenderer(rend, 0, kCGLRPMaxSampleBuffers, &value)) ||
        expect_true("renderer max sample buffers is one", value == 1) ||
        expect_no_error("AO46DescribeRenderer(max samples)",
                        AO46DescribeRenderer(rend, 0, kCGLRPMaxSamples, &value)) ||
        expect_true("renderer max samples is four", value == 4) ||
        expect_no_error("AO46DescribeRenderer(sample modes)",
                        AO46DescribeRenderer(rend, 0, kCGLRPSampleModes, &renderer_sample_modes)) ||
        expect_true("renderer sample mode includes multisample",
                    (renderer_sample_modes & kCGLMultisampleBit) != 0) ||
        expect_no_error("AO46DescribeRenderer(accelerated)",
                        AO46DescribeRenderer(rend, 0, kCGLRPAccelerated, &value)) ||
        expect_true("renderer is accelerated", value == 1)) {
        AO46DestroyRendererInfo(rend);
        return 1;
    }

    AO46DestroyRendererInfo(rend);

    if (expect_no_error("AO46ChoosePixelFormat", AO46ChoosePixelFormat(attribs, &pix, &npix)) ||
        expect_true("pixel format exists", pix != NULL) ||
        expect_true("exactly one pixel format", npix == 1)) {
        return 1;
    }

    if (expect_no_error("AO46DescribePixelFormat(profile)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAOpenGLProfile, &value)) ||
        expect_true("3.2 core request preserved", value == kCGLOGLPVersion_GL3_Core) ||
        expect_no_error("AO46DescribePixelFormat(renderer id)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFARendererID, &renderer_id)) ||
        expect_true("pixel format renderer id matches", renderer_id == 0x414F3436) ||
        expect_no_error("AO46DescribePixelFormat(display mask)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFADisplayMask, &display_mask)) ||
        expect_true("pixel format display mask preserved", display_mask == 0x1) ||
        expect_no_error("AO46DescribePixelFormat(alpha size)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAAlphaSize, &alpha_bits)) ||
        expect_true("pixel format alpha size preserved", alpha_bits == 8) ||
        expect_no_error("AO46DescribePixelFormat(sample buffers)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFASampleBuffers, &sample_buffers)) ||
        expect_true("pixel format sample buffers preserved", sample_buffers == 1) ||
        expect_no_error("AO46DescribePixelFormat(samples)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFASamples, &samples)) ||
        expect_true("pixel format samples preserved", samples == 4) ||
        expect_no_error("AO46DescribePixelFormat(multisample)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAMultisample, &value)) ||
        expect_true("pixel format multisample preserved", value == 1) ||
        expect_no_error("AO46DescribePixelFormat(accelerated)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAAccelerated, &value)) ||
        expect_true("pixel format accelerated preserved", value == 1) ||
        expect_no_error("AO46DescribePixelFormat(offscreen)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAOffScreen, &value)) ||
        expect_true("pixel format offscreen preserved", value == 1) ||
        expect_no_error("AO46DescribePixelFormat(window)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAWindow, &value)) ||
        expect_true("pixel format window preserved", value == 1) ||
        expect_no_error("AO46DescribePixelFormat(pbuffer)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAPBuffer, &value)) ||
        expect_true("pixel format pbuffer preserved", value == 1) ||
        expect_no_error("AO46DescribePixelFormat(virtual screen count)",
                        AO46DescribePixelFormat(pix, 0, kCGLPFAVirtualScreenCount, &virtual_screen_count)) ||
        expect_true("pixel format virtual screen count preserved", virtual_screen_count == 1)) {
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46ChoosePixelFormat(4.6 core)",
                        AO46ChoosePixelFormat(attribs46, &pix46, &npix46)) ||
        expect_true("4.6 pixel format exists", pix46 != NULL) ||
        expect_true("4.6 pixel format count", npix46 == 1) ||
        expect_no_error("AO46DescribePixelFormat(4.6 profile)",
                        AO46DescribePixelFormat(pix46, 0, kCGLPFAOpenGLProfile, &value)) ||
        expect_true("4.6 profile preserved", value == kCGLOGLPVersion_GL4_6_Core)) {
        AO46DestroyPixelFormat(pix46);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    CGLError create46_error = AO46CreateContext(pix46, NULL, &ctx46);
    if (create46_error == kCGLNoError) {
        if (expect_true("4.6 context exists", ctx46 != NULL) ||
            expect_no_error("AO46SetOffScreen(4.6)",
                            AO46SetOffScreen(ctx46, 1, 1, 4, offscreen_storage)) ||
            expect_no_error("AO46SetCurrentContext(4.6)", AO46SetCurrentContext(ctx46))) {
            AO46DestroyContext(ctx46);
            AO46DestroyPixelFormat(pix46);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glGetIntegerv(GL_MAJOR_VERSION, &gl_major);
        glGetIntegerv(GL_MINOR_VERSION, &gl_minor);
        if (expect_true("4.6 request is not silently lowered",
                        gl_version_at_least(gl_major, gl_minor, 4, 6))) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(ctx46);
            AO46DestroyPixelFormat(pix46);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        AO46SetCurrentContext(NULL);
        AO46DestroyContext(ctx46);
    } else if (create46_error == kCGLBadContext && ctx46 == NULL) {
        fprintf(stderr, "native Mesa Asahi winsys is not ready; context creation is correctly blocked\n");
        if (expect_no_error("AO46SetCurrentContext(NULL) without native screen",
                            AO46SetCurrentContext(NULL))) {
            AO46DestroyPixelFormat(pix46);
            AO46DestroyPixelFormat(pix);
            return 1;
        }
        AO46DestroyPixelFormat(pix46);
        AO46DestroyPixelFormat(pix);
        return 0;
    } else if (expect_true("unsupported 4.6 request returns bad pixel format",
                           create46_error == kCGLBadPixelFormat && ctx46 == NULL)) {
        AO46DestroyPixelFormat(pix46);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    AO46DestroyPixelFormat(pix46);

    if (expect_no_error("AO46CreateContext", AO46CreateContext(pix, NULL, &ctx)) ||
        expect_true("context exists", ctx != NULL)) {
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46CreateContext(copy)", AO46CreateContext(pix, NULL, &copy_ctx)) ||
        expect_true("copy context exists", copy_ctx != NULL)) {
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46LockContext", AO46LockContext(ctx)) ||
        expect_no_error("AO46UnlockContext", AO46UnlockContext(ctx))) {
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46EnableContext(rasterization)",
                        AO46EnableContext(ctx, kCGLCERasterization)) ||
        expect_no_error("AO46IsContextEnabled(rasterization)",
                        AO46IsContextEnabled(ctx, kCGLCERasterization, &value)) ||
        expect_true("rasterization enabled", value == 1) ||
        expect_no_error("AO46DisableContext(rasterization)",
                        AO46DisableContext(ctx, kCGLCERasterization)) ||
        expect_no_error("AO46IsContextEnabled(rasterization off)",
                        AO46IsContextEnabled(ctx, kCGLCERasterization, &value)) ||
        expect_true("rasterization disabled", value == 0)) {
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetOffScreen",
                        AO46SetOffScreen(ctx, 4, 4, 16, offscreen_storage)) ||
        expect_no_error("AO46GetOffScreen",
                        AO46GetOffScreen(ctx, &pbuffer_width, &pbuffer_height, &value, &offscreen_ptr)) ||
        expect_true("offscreen width round-trip", pbuffer_width == 4) ||
        expect_true("offscreen height round-trip", pbuffer_height == 4) ||
        expect_true("offscreen rowbytes round-trip", value == 16) ||
        expect_true("offscreen baseaddr round-trip", offscreen_ptr == offscreen_storage)) {
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetCurrentContext(offscreen)", AO46SetCurrentContext(ctx))) {
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    glGetIntegerv(GL_MAJOR_VERSION, &gl_major);
    glGetIntegerv(GL_MINOR_VERSION, &gl_minor);
    if (expect_true("glGetIntegerv(GL_MAJOR_VERSION) reports a core-profile major",
                    gl_major >= 3) ||
        expect_true("glGetIntegerv(GL_MINOR_VERSION) reports a nonnegative minor",
                    gl_minor >= 0) ||
        expect_true("realized GL version is at least 3.2 core",
                    gl_major > 3 || (gl_major == 3 && gl_minor >= 2)) ||
        expect_true("realized GL version stays within requested 4.6 ceiling",
                    gl_major < 4 || (gl_major == 4 && gl_minor <= 6))) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    have_buffer_storage = gl_has_core_or_extension(gl_major, gl_minor,
                                                   4, 4,
                                                   "GL_ARB_buffer_storage");
    have_clear_buffer_object = gl_has_core_or_extension(gl_major, gl_minor,
                                                        4, 3,
                                                        "GL_ARB_clear_buffer_object");
    have_dsa = gl_has_core_or_extension(gl_major, gl_minor,
                                        4, 5,
                                        "GL_ARB_direct_state_access");
    have_shader_storage = gl_has_core_or_extension(gl_major, gl_minor,
                                                   4, 3,
                                                   "GL_ARB_shader_storage_buffer_object");
    have_atomic_counters = gl_has_core_or_extension(gl_major, gl_minor,
                                                    4, 2,
                                                    "GL_ARB_shader_atomic_counters");
    have_texture_storage = gl_has_core_or_extension(gl_major, gl_minor,
                                                    4, 2,
                                                    "GL_ARB_texture_storage");

    gl_string = glGetString(GL_VERSION);
    snprintf(gl_version_prefix, sizeof(gl_version_prefix), "%d.%d", gl_major, gl_minor);
    if (expect_true("glGetString(GL_VERSION) exists", gl_string != NULL) ||
        expect_true("glGetString(GL_VERSION) matches reported major.minor",
                    strstr((const char *)gl_string, gl_version_prefix) != NULL)) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    glViewport(0, 0, 4, 4);
    glGetIntegerv(GL_VIEWPORT, viewport);
    glGetBooleanv(GL_COLOR_WRITEMASK, color_mask);
    if (expect_true("glGetIntegerv(GL_VIEWPORT) round-trip",
                    viewport[0] == 0 && viewport[1] == 0 && viewport[2] == 4 && viewport[3] == 4) ||
        expect_true("glGetBooleanv(GL_COLOR_WRITEMASK) defaults to all true",
                    color_mask[0] && color_mask[1] && color_mask[2] && color_mask[3])) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, readback_pixel);
    if (expect_true("glReadPixels clear round-trip",
                    readback_pixel[0] == 64 &&
                    readback_pixel[1] == 128 &&
                    readback_pixel[2] == 191 &&
                    readback_pixel[3] == 255)) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    glEnable(GL_SCISSOR_TEST);
    glScissor(1, 1, 2, 2);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_SCISSOR_TEST);
    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, scissored_pixel);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, preserved_pixel);
    if (expect_true("glScissor+glClear updates selected pixel",
                    scissored_pixel[0] == 255 &&
                    scissored_pixel[1] == 0 &&
                    scissored_pixel[2] == 0 &&
                    scissored_pixel[3] == 255) ||
        expect_true("glScissor preserves untouched pixel",
                    preserved_pixel[0] == 64 &&
                    preserved_pixel[1] == 128 &&
                    preserved_pixel[2] == 191 &&
                    preserved_pixel[3] == 255)) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    gl_string = glGetString(GL_EXTENSIONS);
    value = (GLint)glGetError();
    if (expect_true("glGetString(GL_EXTENSIONS) returns null in core profile", gl_string == NULL) ||
        expect_true("glGetError reports invalid enum for GL_EXTENSIONS", value == GL_INVALID_ENUM) ||
        expect_true("glGetError clears the error flag", glGetError() == GL_NO_ERROR)) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetOffScreen(triangle)",
                        AO46SetOffScreen(ctx, 32, 32, 32 * 4, triangle_storage))) {
        AO46SetCurrentContext(NULL);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    {
        static const GLchar *vertex_shader_source =
            "#version 150 core\n"
            "in vec2 position;\n"
            "in vec4 color;\n"
            "out vec4 vertexColor;\n"
            "void main(void)\n"
            "{\n"
            "    vertexColor = color;\n"
            "    gl_Position = vec4(position, 0.0, 1.0);\n"
            "}\n";
        static const GLchar *fragment_shader_source =
            "#version 150 core\n"
            "in vec4 vertexColor;\n"
            "out vec4 fragColor;\n"
            "void main(void)\n"
            "{\n"
            "    fragColor = vertexColor;\n"
            "}\n";
        static const GLfloat triangle_vertices[] = {
            -0.6f, -0.6f, 1.0f, 0.0f, 0.0f, 1.0f,
             0.6f, -0.6f, 0.0f, 1.0f, 0.0f, 1.0f,
             0.0f,  0.6f, 0.0f, 0.0f, 1.0f, 1.0f
        };
        static const GLfloat shifted_triangle_vertices[] = {
            -0.95f, -0.95f, 1.0f, 0.0f, 0.0f, 1.0f,
            -0.15f, -0.95f, 0.0f, 1.0f, 0.0f, 1.0f,
            -0.55f, -0.15f, 0.0f, 0.0f, 1.0f, 1.0f
        };
        static const GLfloat mapped_storage_triangle_vertices[] = {
             0.15f, -0.95f, 1.0f, 0.0f, 0.0f, 1.0f,
             0.95f, -0.95f, 0.0f, 1.0f, 0.0f, 1.0f,
             0.55f, -0.15f, 0.0f, 0.0f, 1.0f, 1.0f
        };
        static const GLushort triangle_indices[] = { 0, 1, 2 };

        glViewport(0, 0, 32, 32);
        glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &max_vertex_attribs);
        if (expect_true("glGetIntegerv(GL_MAX_VERTEX_ATTRIBS)", max_vertex_attribs >= 2)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        vertex_shader = glCreateShader(GL_VERTEX_SHADER);
        fragment_shader = glCreateShader(GL_FRAGMENT_SHADER);
        program = glCreateProgram();
        if (expect_true("glCreateShader(GL_VERTEX_SHADER)", vertex_shader != 0) ||
            expect_true("glCreateShader(GL_FRAGMENT_SHADER)", fragment_shader != 0) ||
            expect_true("glCreateProgram", program != 0) ||
            expect_true("glIsShader(vertex)", glIsShader(vertex_shader) == GL_TRUE) ||
            expect_true("glIsShader(fragment)", glIsShader(fragment_shader) == GL_TRUE) ||
            expect_true("glIsProgram(program)", glIsProgram(program) == GL_TRUE)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glShaderSource(vertex_shader, 1, &vertex_shader_source, NULL);
        glCompileShader(vertex_shader);
        glGetShaderiv(vertex_shader, GL_COMPILE_STATUS, &compile_status);
        if (expect_true("vertex shader compiles", compile_status == GL_TRUE)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glShaderSource(fragment_shader, 1, &fragment_shader_source, NULL);
        glCompileShader(fragment_shader);
        glGetShaderiv(fragment_shader, GL_COMPILE_STATUS, &compile_status);
        if (expect_true("fragment shader compiles", compile_status == GL_TRUE)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glAttachShader(program, vertex_shader);
        glAttachShader(program, fragment_shader);
        glBindAttribLocation(program, 0, "position");
        glBindAttribLocation(program, 1, "color");
        glLinkProgram(program);
        glValidateProgram(program);
        glGetProgramiv(program, GL_LINK_STATUS, &link_status);
        glGetProgramiv(program, GL_VALIDATE_STATUS, &validate_status);
        glGetProgramiv(program, GL_ATTACHED_SHADERS, &attached_shader_count);
        glGetProgramiv(program, GL_ACTIVE_ATTRIBUTES, &active_attribute_count);
        attrib_location = glGetAttribLocation(program, "position");
        if (expect_true("program links", link_status == GL_TRUE) ||
            expect_true("program validates", validate_status == GL_TRUE) ||
            expect_true("attached shader count", attached_shader_count == 2) ||
            expect_true("active attribute count", active_attribute_count == 2) ||
            expect_true("position attribute location", attrib_location == 0)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glUseProgram(program);
        glGetIntegerv(GL_CURRENT_PROGRAM, &current_program);
        if (expect_true("GL_CURRENT_PROGRAM reflects glUseProgram", current_program == (GLint)program)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(triangle_vertices), triangle_vertices, GL_STATIC_DRAW);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &array_buffer_binding);
        glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &buffer_size);
        glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_USAGE, &buffer_usage);
        if (expect_true("glGenBuffers produced buffer", vbo != 0) ||
            expect_true("glIsBuffer(vbo)", glIsBuffer(vbo) == GL_TRUE) ||
            expect_true("GL_ARRAY_BUFFER_BINDING reflects VBO", array_buffer_binding == (GLint)vbo) ||
            expect_true("GL_BUFFER_SIZE reflects uploaded data",
                        buffer_size == (GLint)sizeof(triangle_vertices)) ||
            expect_true("GL_BUFFER_USAGE reflects uploaded usage", buffer_usage == GL_STATIC_DRAW)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glGenVertexArrays(1, &vao);
        glBindVertexArray(vao);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertex_array_binding);
        if (expect_true("glGenVertexArrays produced VAO", vao != 0) ||
            expect_true("glIsVertexArray(vao)", glIsVertexArray(vao) == GL_TRUE) ||
            expect_true("GL_VERTEX_ARRAY_BINDING reflects VAO", vertex_array_binding == (GLint)vao)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 6 * (GLsizei)sizeof(GLfloat), (const void *)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1,
                              4,
                              GL_FLOAT,
                              GL_FALSE,
                              6 * (GLsizei)sizeof(GLfloat),
                              (const void *)(2 * sizeof(GLfloat)));

        glGenBuffers(1, &ebo);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(triangle_indices), triangle_indices, GL_STATIC_DRAW);
        glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &element_array_buffer_binding);
        if (expect_true("glGenBuffers produced element buffer", ebo != 0) ||
            expect_true("glIsBuffer(ebo)", glIsBuffer(ebo) == GL_TRUE) ||
            expect_true("GL_ELEMENT_ARRAY_BUFFER_BINDING reflects EBO",
                        element_array_buffer_binding == (GLint)ebo)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        if (expect_true("triangle draw completes without GL error", glGetError() == GL_NO_ERROR)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, triangle_pixel);

        glClear(GL_COLOR_BUFFER_BIT);
        glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, (const void *)0);
        if (expect_true("indexed triangle draw completes without GL error", glGetError() == GL_NO_ERROR)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, indexed_triangle_pixel);
        glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, background_pixel);
        if (expect_true("triangle center pixel is shaded",
                        triangle_pixel[0] > 0 &&
                        triangle_pixel[1] > 0 &&
                        triangle_pixel[2] > 0 &&
                        triangle_pixel[3] == 255) ||
            expect_true("indexed triangle center pixel is shaded",
                        indexed_triangle_pixel[0] > 0 &&
                        indexed_triangle_pixel[1] > 0 &&
                        indexed_triangle_pixel[2] > 0 &&
                        indexed_triangle_pixel[3] == 255) ||
            expect_true("background pixel remains cleared",
                        background_pixel[0] == 0 &&
                        background_pixel[1] == 0 &&
                        background_pixel[2] == 0 &&
                        background_pixel[3] == 255)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(shifted_triangle_vertices), shifted_triangle_vertices);
        glClear(GL_COLOR_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, moved_triangle_center_pixel);
        glReadPixels(6, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, moved_triangle_corner_pixel);
        if (expect_true("glBufferSubData updates draw-time vertex data without GL error", glGetError() == GL_NO_ERROR) ||
            expect_true("updated triangle vacates the old center pixel",
                        moved_triangle_center_pixel[0] == 0 &&
                        moved_triangle_center_pixel[1] == 0 &&
                        moved_triangle_center_pixel[2] == 0 &&
                        moved_triangle_center_pixel[3] == 255) ||
            expect_true("updated triangle shades its new corner region",
                        moved_triangle_corner_pixel[0] > 0 &&
                        moved_triangle_corner_pixel[1] > 0 &&
                        moved_triangle_corner_pixel[2] > 0 &&
                        moved_triangle_corner_pixel[3] == 255)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }

        if (have_buffer_storage) {
            const GLbitfield storage_flags = GL_DYNAMIC_STORAGE_BIT |
                                             GL_MAP_READ_BIT |
                                             GL_MAP_WRITE_BIT;
            GLfloat *mapped_vertices = NULL;
            const GLfloat *read_only_vertices = NULL;
            void *mapped_pointer = NULL;
            GLint buffer_mapped = 0;
            GLint buffer_access_flags = 0;
            GLint buffer_map_length = 0;
            GLint buffer_map_offset = -1;
            GLint buffer_immutable_storage = 0;
            GLint buffer_storage_flags = 0;
            GLboolean unmap_ok = GL_FALSE;
            GLubyte mapped_storage_new_pixel[4] = { 0 };
            GLubyte mapped_storage_old_pixel[4] = { 0 };
            GLubyte mapped_storage_center_pixel[4] = { 0 };

            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferStorage(GL_ARRAY_BUFFER, sizeof(mapped_storage_triangle_vertices), NULL, storage_flags);
            glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_IMMUTABLE_STORAGE, &buffer_immutable_storage);
            glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_STORAGE_FLAGS, &buffer_storage_flags);
            if (expect_true("glBufferStorage creates immutable storage", buffer_immutable_storage == GL_TRUE) ||
                expect_true("GL_BUFFER_STORAGE_FLAGS reflects immutable buffer flags",
                            buffer_storage_flags == (GLint)storage_flags) ||
                expect_true("glBufferStorage leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            mapped_vertices = (GLfloat *)glMapBufferRange(GL_ARRAY_BUFFER,
                                                          0,
                                                          sizeof(mapped_storage_triangle_vertices),
                                                          GL_MAP_READ_BIT |
                                                              GL_MAP_WRITE_BIT |
                                                              GL_MAP_FLUSH_EXPLICIT_BIT);
            glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_MAPPED, &buffer_mapped);
            glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_ACCESS_FLAGS, &buffer_access_flags);
            glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_MAP_LENGTH, &buffer_map_length);
            glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_MAP_OFFSET, &buffer_map_offset);
            glGetBufferPointerv(GL_ARRAY_BUFFER, GL_BUFFER_MAP_POINTER, &mapped_pointer);
            if (expect_true("glMapBufferRange returns a writable pointer", mapped_vertices != NULL) ||
                expect_true("GL_BUFFER_MAPPED reflects active mapping", buffer_mapped == GL_TRUE) ||
                expect_true("GL_BUFFER_ACCESS_FLAGS reflects explicit map flags",
                            buffer_access_flags == (GLint)(GL_MAP_READ_BIT |
                                                           GL_MAP_WRITE_BIT |
                                                           GL_MAP_FLUSH_EXPLICIT_BIT)) ||
                expect_true("GL_BUFFER_MAP_LENGTH reports mapped byte count",
                            buffer_map_length == (GLint)sizeof(mapped_storage_triangle_vertices)) ||
                expect_true("GL_BUFFER_MAP_OFFSET reports zero-based mapping", buffer_map_offset == 0) ||
                expect_true("glGetBufferPointerv reports the active mapped pointer",
                            mapped_pointer == (void *)mapped_vertices) ||
                expect_true("glMapBufferRange leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            memcpy(mapped_vertices, mapped_storage_triangle_vertices, sizeof(mapped_storage_triangle_vertices));
            glDrawArrays(GL_TRIANGLES, 0, 3);
            value = glGetError();
            if (expect_true("mapped array-buffer draw reports either driver-allowed execution or GL rejection",
                            value == GL_NO_ERROR || value == GL_INVALID_OPERATION)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glFlushMappedBufferRange(GL_ARRAY_BUFFER, 0, sizeof(mapped_storage_triangle_vertices));
            unmap_ok = glUnmapBuffer(GL_ARRAY_BUFFER);
            glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_MAPPED, &buffer_mapped);
            if (expect_true("glUnmapBuffer succeeds for explicit-flush storage", unmap_ok == GL_TRUE) ||
                expect_true("GL_BUFFER_MAPPED clears after glUnmapBuffer", buffer_mapped == GL_FALSE) ||
                expect_true("flush and unmap leave no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            read_only_vertices = (const GLfloat *)glMapBuffer(GL_ARRAY_BUFFER, GL_READ_ONLY);
            if (expect_true("glMapBuffer(GL_READ_ONLY) returns immutable storage", read_only_vertices != NULL) ||
                expect_true("read-only mapping round-trips the uploaded storage bytes",
                            memcmp(read_only_vertices,
                                   mapped_storage_triangle_vertices,
                                   sizeof(mapped_storage_triangle_vertices)) == 0) ||
                expect_true("read-only map leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            unmap_ok = glUnmapBuffer(GL_ARRAY_BUFFER);
            if (expect_true("glUnmapBuffer succeeds for read-only mapping", unmap_ok == GL_TRUE) ||
                expect_true("read-only unmap leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glReadPixels(25, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, mapped_storage_new_pixel);
            glReadPixels(6, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, mapped_storage_old_pixel);
            glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, mapped_storage_center_pixel);
            if (expect_true("immutable-storage draw completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("mapped immutable-storage triangle shades its new right-side region",
                            mapped_storage_new_pixel[0] > 0 &&
                            mapped_storage_new_pixel[1] > 0 &&
                            mapped_storage_new_pixel[2] > 0 &&
                            mapped_storage_new_pixel[3] == 255) ||
                expect_true("mapped immutable-storage triangle vacates the old left-side region",
                            mapped_storage_old_pixel[0] == 0 &&
                            mapped_storage_old_pixel[1] == 0 &&
                            mapped_storage_old_pixel[2] == 0 &&
                            mapped_storage_old_pixel[3] == 255) ||
                expect_true("mapped immutable-storage triangle stays out of the old center region",
                            mapped_storage_center_pixel[0] == 0 &&
                            mapped_storage_center_pixel[1] == 0 &&
                            mapped_storage_center_pixel[2] == 0 &&
                            mapped_storage_center_pixel[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glBufferData(GL_ARRAY_BUFFER, sizeof(triangle_vertices), triangle_vertices, GL_STATIC_DRAW);
            if (expect_true("glBufferData rejects immutable buffer storage", glGetError() == GL_INVALID_OPERATION)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferSubData(GL_ARRAY_BUFFER,
                            0,
                            sizeof(mapped_storage_triangle_vertices),
                            mapped_storage_triangle_vertices);
            if (expect_true("legacy mapped-storage fallback updates VBO contents",
                            glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }
        }

        {
            const GLfloat clear_position = 0.25f;
            GLfloat zero_vertex_data[18] = { 0.0f };
            const GLfloat *cleared_vertices = NULL;
            GLubyte copied_triangle_new_pixel[4] = { 0 };
            GLubyte copied_triangle_old_pixel[4] = { 0 };

            glGenBuffers(1, &copy_vbo);
            glBindBuffer(GL_COPY_READ_BUFFER, vbo);
            glBindBuffer(GL_COPY_WRITE_BUFFER, copy_vbo);
            glBufferData(GL_COPY_WRITE_BUFFER, sizeof(mapped_storage_triangle_vertices), NULL, GL_STATIC_DRAW);
            glGetIntegerv(GL_COPY_READ_BUFFER_BINDING, &copy_read_buffer_binding);
            glGetIntegerv(GL_COPY_WRITE_BUFFER_BINDING, &copy_write_buffer_binding);
            glCopyBufferSubData(GL_COPY_READ_BUFFER,
                                GL_COPY_WRITE_BUFFER,
                                0,
                                0,
                                sizeof(mapped_storage_triangle_vertices));
            if (expect_true("glGenBuffers produced copy destination buffer", copy_vbo != 0) ||
                expect_true("GL_COPY_READ_BUFFER_BINDING reflects source buffer",
                            copy_read_buffer_binding == (GLint)vbo) ||
                expect_true("GL_COPY_WRITE_BUFFER_BINDING reflects destination buffer",
                            copy_write_buffer_binding == (GLint)copy_vbo) ||
                expect_true("glCopyBufferSubData completes without GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glBindBuffer(GL_ARRAY_BUFFER, copy_vbo);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 6 * (GLsizei)sizeof(GLfloat), (const void *)0);
            glVertexAttribPointer(1,
                                  4,
                                  GL_FLOAT,
                                  GL_FALSE,
                                  6 * (GLsizei)sizeof(GLfloat),
                                  (const void *)(2 * sizeof(GLfloat)));
            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glReadPixels(25, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, copied_triangle_new_pixel);
            glReadPixels(6, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, copied_triangle_old_pixel);
            if (expect_true("copied buffer draw completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("copied buffer reproduces the right-side triangle",
                            copied_triangle_new_pixel[0] > 0 &&
                            copied_triangle_new_pixel[1] > 0 &&
                            copied_triangle_new_pixel[2] > 0 &&
                            copied_triangle_new_pixel[3] == 255) ||
                expect_true("copied buffer leaves the old left-side region clear",
                            copied_triangle_old_pixel[0] == 0 &&
                            copied_triangle_old_pixel[1] == 0 &&
                            copied_triangle_old_pixel[2] == 0 &&
                            copied_triangle_old_pixel[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            if (have_clear_buffer_object) {
                glClearBufferSubData(GL_COPY_WRITE_BUFFER,
                                     GL_R32F,
                                     0,
                                     2 * (GLsizeiptr)sizeof(GLfloat),
                                     GL_RED,
                                     GL_FLOAT,
                                     &clear_position);
                cleared_vertices = (const GLfloat *)glMapBuffer(GL_COPY_WRITE_BUFFER, GL_READ_ONLY);
                if (expect_true("glClearBufferSubData completes without GL error", glGetError() == GL_NO_ERROR) ||
                    expect_true("glMapBuffer reads back clear-subdata result", cleared_vertices != NULL) ||
                    expect_true("glClearBufferSubData rewrites the first vertex position pattern",
                                cleared_vertices[0] == clear_position &&
                                cleared_vertices[1] == clear_position) ||
                    expect_true("glUnmapBuffer succeeds after clear-subdata readback",
                                glUnmapBuffer(GL_COPY_WRITE_BUFFER) == GL_TRUE) ||
                    expect_true("clear-subdata unmap leaves no GL error", glGetError() == GL_NO_ERROR)) {
                    AO46SetCurrentContext(NULL);
                    AO46DestroyContext(copy_ctx);
                    AO46DestroyContext(ctx);
                    AO46DestroyPixelFormat(pix);
                    return 1;
                }

                glClearBufferData(GL_COPY_WRITE_BUFFER, GL_R32F, GL_RED, GL_FLOAT, NULL);
                cleared_vertices = (const GLfloat *)glMapBuffer(GL_COPY_WRITE_BUFFER, GL_READ_ONLY);
                if (expect_true("glClearBufferData completes without GL error", glGetError() == GL_NO_ERROR) ||
                    expect_true("glMapBuffer reads back full-buffer clear result", cleared_vertices != NULL) ||
                    expect_true("glClearBufferData zero-fills the destination buffer",
                                memcmp(cleared_vertices,
                                       zero_vertex_data,
                                       sizeof(zero_vertex_data)) == 0) ||
                    expect_true("glUnmapBuffer succeeds after full clear readback",
                                glUnmapBuffer(GL_COPY_WRITE_BUFFER) == GL_TRUE) ||
                    expect_true("full clear unmap leaves no GL error", glGetError() == GL_NO_ERROR)) {
                    AO46SetCurrentContext(NULL);
                    AO46DestroyContext(copy_ctx);
                    AO46DestroyContext(ctx);
                    AO46DestroyPixelFormat(pix);
                    return 1;
                }

                glBindBuffer(GL_ARRAY_BUFFER, copy_vbo);
                glClear(GL_COLOR_BUFFER_BIT);
                glDrawArrays(GL_TRIANGLES, 0, 3);
                glReadPixels(25, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, copied_triangle_new_pixel);
                if (expect_true("cleared copy buffer draw completes without GL error", glGetError() == GL_NO_ERROR) ||
                    expect_true("fully cleared copy buffer no longer shades the copied triangle region",
                                copied_triangle_new_pixel[0] == 0 &&
                                copied_triangle_new_pixel[1] == 0 &&
                                copied_triangle_new_pixel[2] == 0 &&
                                copied_triangle_new_pixel[3] == 255)) {
                    AO46SetCurrentContext(NULL);
                    AO46DestroyContext(copy_ctx);
                    AO46DestroyContext(ctx);
                    AO46DestroyPixelFormat(pix);
                    return 1;
                }
            }
        }

        if (have_dsa &&
            have_shader_storage &&
            have_atomic_counters &&
            gl_version_at_least(gl_major, gl_minor, 4, 5)) {
            static const GLbitfield named_storage_flags = GL_DYNAMIC_STORAGE_BIT |
                                                          GL_MAP_READ_BIT |
                                                          GL_MAP_WRITE_BIT;
            const GLfloat named_clear_position = -0.35f;
            GLfloat bindful_readback_vertices[18] = { 0.0f };
            GLfloat named_readback_vertices[18] = { 0.0f };
            GLfloat named_zero_vertices[18] = { 0.0f };
            const GLfloat *mapped_named_vertices = NULL;
            void *mapped_named_pointer = NULL;
            GLint named_buffer_size = 0;
            GLint named_buffer_usage = 0;
            GLint named_buffer_mapped = 0;
            GLint named_buffer_immutable_storage = 0;
            GLint named_buffer_storage_flags = 0;
            GLint pixel_pack_buffer_binding = 0;
            GLint pixel_unpack_buffer_binding = 0;
            GLint draw_indirect_buffer_binding = 0;
            GLint dispatch_indirect_buffer_binding = 0;
            GLint uniform_buffer_binding = 0;
            GLint transform_feedback_buffer_binding = 0;
            GLint atomic_counter_buffer_binding = 0;
            GLint shader_storage_buffer_binding = 0;
            GLint indexed_uniform_buffer_binding = 0;
            GLint indexed_transform_feedback_buffer_binding = 0;
            GLint indexed_atomic_counter_buffer_binding = 0;
            GLint indexed_shader_storage_buffer_binding = 0;
            GLint max_transform_feedback_buffers = 0;
            GLint max_uniform_buffer_bindings = 0;
            GLint max_atomic_counter_buffer_bindings = 0;
            GLint max_shader_storage_buffer_bindings = 0;
            GLint uniform_buffer_offset_alignment = 0;
            GLint shader_storage_buffer_offset_alignment = 0;
            GLint64 named_buffer_size64 = 0;
            GLint64 named_buffer_storage_flags64 = 0;
            GLint64 bound_uniform_buffer_size64 = 0;
            GLint64 indexed_uniform_buffer_start64 = 0;
            GLint64 indexed_uniform_buffer_size64 = 0;
            GLint64 indexed_transform_feedback_buffer_start64 = 0;
            GLint64 indexed_transform_feedback_buffer_size64 = 0;
            GLint64 indexed_atomic_counter_buffer_start64 = 0;
            GLint64 indexed_atomic_counter_buffer_size64 = 0;
            GLint64 indexed_shader_storage_buffer_start64 = 0;
            GLint64 indexed_shader_storage_buffer_size64 = 0;
            GLubyte dsa_triangle_pixel[4] = { 0 };
            GLubyte dsa_background_pixel[4] = { 0 };
            GLubyte dsa_copied_triangle_pixel[4] = { 0 };
            GLubyte dsa_cleared_triangle_pixel[4] = { 0 };

            glBindBuffer(GL_COPY_READ_BUFFER, vbo);
            glGetBufferSubData(GL_COPY_READ_BUFFER,
                               0,
                               sizeof(bindful_readback_vertices),
                               bindful_readback_vertices);
            if (expect_true("glGetBufferSubData completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("glGetBufferSubData reads back the source buffer contents",
                            memcmp(bindful_readback_vertices,
                                   mapped_storage_triangle_vertices,
                                   sizeof(mapped_storage_triangle_vertices)) == 0)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glCreateBuffers(1, &dsa_vbo);
            glCreateBuffers(1, &dsa_immutable_vbo);
            glNamedBufferData(dsa_vbo,
                              sizeof(shifted_triangle_vertices),
                              shifted_triangle_vertices,
                              GL_STATIC_DRAW);
            glGetNamedBufferParameteriv(dsa_vbo, GL_BUFFER_SIZE, &named_buffer_size);
            glGetNamedBufferParameteriv(dsa_vbo, GL_BUFFER_USAGE, &named_buffer_usage);
            glGetNamedBufferSubData(dsa_vbo,
                                    0,
                                    sizeof(named_readback_vertices),
                                    named_readback_vertices);
            mapped_named_vertices = (const GLfloat *)glMapNamedBufferRange(dsa_vbo,
                                                                           0,
                                                                           sizeof(named_readback_vertices),
                                                                           GL_MAP_READ_BIT);
            glGetNamedBufferParameteriv(dsa_vbo, GL_BUFFER_MAPPED, &named_buffer_mapped);
            glGetNamedBufferPointerv(dsa_vbo, GL_BUFFER_MAP_POINTER, &mapped_named_pointer);
            if (expect_true("glCreateBuffers produced DSA buffers", dsa_vbo != 0 && dsa_immutable_vbo != 0) ||
                expect_true("glIsBuffer(dsa_vbo)", glIsBuffer(dsa_vbo) == GL_TRUE) ||
                expect_true("glNamedBufferData leaves no GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("glGetNamedBufferParameteriv reports DSA buffer size",
                            named_buffer_size == (GLint)sizeof(shifted_triangle_vertices)) ||
                expect_true("glGetNamedBufferParameteriv reports DSA buffer usage",
                            named_buffer_usage == GL_STATIC_DRAW) ||
                expect_true("glGetNamedBufferSubData round-trips DSA buffer bytes",
                            memcmp(named_readback_vertices,
                                   shifted_triangle_vertices,
                                   sizeof(shifted_triangle_vertices)) == 0) ||
                expect_true("glMapNamedBufferRange returns a DSA mapping", mapped_named_vertices != NULL) ||
                expect_true("GL_BUFFER_MAPPED reflects a named mapping", named_buffer_mapped == GL_TRUE) ||
                expect_true("glGetNamedBufferPointerv reports the active named mapping",
                            mapped_named_pointer == (void *)mapped_named_vertices) ||
                expect_true("glMapNamedBufferRange sees the uploaded DSA data",
                            memcmp(mapped_named_vertices,
                                   shifted_triangle_vertices,
                                   sizeof(shifted_triangle_vertices)) == 0) ||
                expect_true("glUnmapNamedBuffer succeeds for DSA readback",
                            glUnmapNamedBuffer(dsa_vbo) == GL_TRUE) ||
                expect_true("DSA readback unmap leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glBindBuffer(GL_ARRAY_BUFFER, dsa_vbo);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 6 * (GLsizei)sizeof(GLfloat), (const void *)0);
            glVertexAttribPointer(1,
                                  4,
                                  GL_FLOAT,
                                  GL_FALSE,
                                  6 * (GLsizei)sizeof(GLfloat),
                                  (const void *)(2 * sizeof(GLfloat)));
            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glReadPixels(6, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, dsa_triangle_pixel);
            glReadPixels(25, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, dsa_background_pixel);
            if (expect_true("DSA-uploaded draw completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("DSA-uploaded buffer shades the shifted triangle region",
                            dsa_triangle_pixel[0] > 0 &&
                            dsa_triangle_pixel[1] > 0 &&
                            dsa_triangle_pixel[2] > 0 &&
                            dsa_triangle_pixel[3] == 255) ||
                expect_true("DSA-uploaded buffer leaves the opposite region clear",
                            dsa_background_pixel[0] == 0 &&
                            dsa_background_pixel[1] == 0 &&
                            dsa_background_pixel[2] == 0 &&
                            dsa_background_pixel[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glCopyNamedBufferSubData(vbo, dsa_vbo, 0, 0, sizeof(mapped_storage_triangle_vertices));
            glGetNamedBufferSubData(dsa_vbo,
                                    0,
                                    sizeof(named_readback_vertices),
                                    named_readback_vertices);
            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glReadPixels(25, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, dsa_copied_triangle_pixel);
            if (expect_true("glCopyNamedBufferSubData completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("glCopyNamedBufferSubData updates the DSA buffer contents",
                            memcmp(named_readback_vertices,
                                   mapped_storage_triangle_vertices,
                                   sizeof(mapped_storage_triangle_vertices)) == 0) ||
                expect_true("copied DSA buffer shades the right-side triangle region",
                            dsa_copied_triangle_pixel[0] > 0 &&
                            dsa_copied_triangle_pixel[1] > 0 &&
                            dsa_copied_triangle_pixel[2] > 0 &&
                            dsa_copied_triangle_pixel[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glClearNamedBufferSubData(dsa_vbo,
                                      GL_R32F,
                                      0,
                                      2 * (GLsizeiptr)sizeof(GLfloat),
                                      GL_RED,
                                      GL_FLOAT,
                                      &named_clear_position);
            glGetNamedBufferSubData(dsa_vbo, 0, 2 * (GLsizeiptr)sizeof(GLfloat), named_readback_vertices);
            if (expect_true("glClearNamedBufferSubData completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("glClearNamedBufferSubData rewrites the first named vertex position pattern",
                            named_readback_vertices[0] == named_clear_position &&
                            named_readback_vertices[1] == named_clear_position)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glClearNamedBufferData(dsa_vbo, GL_R32F, GL_RED, GL_FLOAT, NULL);
            glGetNamedBufferSubData(dsa_vbo, 0, sizeof(named_readback_vertices), named_readback_vertices);
            glBindBuffer(GL_ARRAY_BUFFER, dsa_vbo);
            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glReadPixels(25, 6, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, dsa_cleared_triangle_pixel);
            if (expect_true("glClearNamedBufferData completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("glClearNamedBufferData zero-fills the DSA buffer",
                            memcmp(named_readback_vertices,
                                   named_zero_vertices,
                                   sizeof(named_zero_vertices)) == 0) ||
                expect_true("cleared DSA buffer no longer shades the copied triangle region",
                            dsa_cleared_triangle_pixel[0] == 0 &&
                            dsa_cleared_triangle_pixel[1] == 0 &&
                            dsa_cleared_triangle_pixel[2] == 0 &&
                            dsa_cleared_triangle_pixel[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glNamedBufferStorage(dsa_immutable_vbo,
                                 sizeof(mapped_storage_triangle_vertices),
                                 mapped_storage_triangle_vertices,
                                 named_storage_flags);
            glGetNamedBufferParameteriv(dsa_immutable_vbo,
                                        GL_BUFFER_IMMUTABLE_STORAGE,
                                        &named_buffer_immutable_storage);
            glGetNamedBufferParameteriv(dsa_immutable_vbo,
                                        GL_BUFFER_STORAGE_FLAGS,
                                        &named_buffer_storage_flags);
            mapped_named_vertices = (const GLfloat *)glMapNamedBuffer(dsa_immutable_vbo, GL_READ_ONLY);
            if (expect_true("glNamedBufferStorage completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("glNamedBufferStorage creates immutable DSA storage",
                            named_buffer_immutable_storage == GL_TRUE) ||
                expect_true("GL_BUFFER_STORAGE_FLAGS reflects named immutable flags",
                            named_buffer_storage_flags == (GLint)named_storage_flags) ||
                expect_true("glMapNamedBuffer returns immutable DSA storage", mapped_named_vertices != NULL) ||
                expect_true("glMapNamedBuffer reads back named immutable bytes",
                            memcmp(mapped_named_vertices,
                                   mapped_storage_triangle_vertices,
                                   sizeof(mapped_storage_triangle_vertices)) == 0) ||
                expect_true("glUnmapNamedBuffer succeeds for immutable DSA storage",
                            glUnmapNamedBuffer(dsa_immutable_vbo) == GL_TRUE) ||
                expect_true("immutable DSA unmap leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glNamedBufferData(dsa_immutable_vbo,
                              sizeof(triangle_vertices),
                              triangle_vertices,
                              GL_STATIC_DRAW);
            if (expect_true("glNamedBufferData rejects immutable named storage",
                            glGetError() == GL_INVALID_OPERATION)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glBindBuffer(GL_PIXEL_PACK_BUFFER, dsa_vbo);
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, dsa_immutable_vbo);
            glBindBuffer(GL_DRAW_INDIRECT_BUFFER, dsa_vbo);
            glBindBuffer(GL_DISPATCH_INDIRECT_BUFFER, dsa_immutable_vbo);
            glBindBufferBase(GL_UNIFORM_BUFFER, 1, dsa_immutable_vbo);
            glBindBufferRange(GL_TRANSFORM_FEEDBACK_BUFFER, 0, dsa_immutable_vbo, 8, 24);
            glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 3, dsa_immutable_vbo);
            glBindBufferRange(GL_SHADER_STORAGE_BUFFER, 2, dsa_immutable_vbo, 0, 32);
            value = glGetError();
            if (value == GL_NO_ERROR) {
                glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pixel_pack_buffer_binding);
                glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pixel_unpack_buffer_binding);
                glGetIntegerv(GL_DRAW_INDIRECT_BUFFER_BINDING, &draw_indirect_buffer_binding);
                glGetIntegerv(GL_DISPATCH_INDIRECT_BUFFER_BINDING, &dispatch_indirect_buffer_binding);
                glGetIntegerv(GL_UNIFORM_BUFFER_BINDING, &uniform_buffer_binding);
                glGetIntegerv(GL_TRANSFORM_FEEDBACK_BUFFER_BINDING, &transform_feedback_buffer_binding);
                glGetIntegerv(GL_ATOMIC_COUNTER_BUFFER_BINDING, &atomic_counter_buffer_binding);
                glGetIntegerv(GL_SHADER_STORAGE_BUFFER_BINDING, &shader_storage_buffer_binding);
                glGetIntegeri_v(GL_UNIFORM_BUFFER_BINDING, 1, &indexed_uniform_buffer_binding);
                glGetIntegeri_v(GL_TRANSFORM_FEEDBACK_BUFFER_BINDING, 0, &indexed_transform_feedback_buffer_binding);
                glGetIntegeri_v(GL_ATOMIC_COUNTER_BUFFER_BINDING, 3, &indexed_atomic_counter_buffer_binding);
                glGetIntegeri_v(GL_SHADER_STORAGE_BUFFER_BINDING, 2, &indexed_shader_storage_buffer_binding);
                glGetInteger64i_v(GL_UNIFORM_BUFFER_START, 1, &indexed_uniform_buffer_start64);
                glGetInteger64i_v(GL_UNIFORM_BUFFER_SIZE, 1, &indexed_uniform_buffer_size64);
                glGetInteger64i_v(GL_TRANSFORM_FEEDBACK_BUFFER_START, 0, &indexed_transform_feedback_buffer_start64);
                glGetInteger64i_v(GL_TRANSFORM_FEEDBACK_BUFFER_SIZE, 0, &indexed_transform_feedback_buffer_size64);
                glGetInteger64i_v(GL_ATOMIC_COUNTER_BUFFER_START, 3, &indexed_atomic_counter_buffer_start64);
                glGetInteger64i_v(GL_ATOMIC_COUNTER_BUFFER_SIZE, 3, &indexed_atomic_counter_buffer_size64);
                glGetInteger64i_v(GL_SHADER_STORAGE_BUFFER_START, 2, &indexed_shader_storage_buffer_start64);
                glGetInteger64i_v(GL_SHADER_STORAGE_BUFFER_SIZE, 2, &indexed_shader_storage_buffer_size64);
                glGetBufferParameteri64v(GL_UNIFORM_BUFFER, GL_BUFFER_SIZE, &bound_uniform_buffer_size64);
                glGetNamedBufferParameteri64v(dsa_immutable_vbo, GL_BUFFER_SIZE, &named_buffer_size64);
                glGetNamedBufferParameteri64v(dsa_immutable_vbo,
                                              GL_BUFFER_STORAGE_FLAGS,
                                              &named_buffer_storage_flags64);
                glGetIntegerv(GL_MAX_TRANSFORM_FEEDBACK_BUFFERS, &max_transform_feedback_buffers);
                glGetIntegerv(GL_MAX_UNIFORM_BUFFER_BINDINGS, &max_uniform_buffer_bindings);
                glGetIntegerv(GL_MAX_ATOMIC_COUNTER_BUFFER_BINDINGS,
                              &max_atomic_counter_buffer_bindings);
                glGetIntegerv(GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS,
                              &max_shader_storage_buffer_bindings);
                glGetIntegerv(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT, &uniform_buffer_offset_alignment);
                glGetIntegerv(GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT,
                              &shader_storage_buffer_offset_alignment);
                if (expect_true("broader buffer target queries leave no GL error", glGetError() == GL_NO_ERROR) ||
                    expect_true("GL_PIXEL_PACK_BUFFER_BINDING reflects bindful state",
                                pixel_pack_buffer_binding == (GLint)dsa_vbo) ||
                    expect_true("GL_PIXEL_UNPACK_BUFFER_BINDING reflects bindful state",
                                pixel_unpack_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("GL_DRAW_INDIRECT_BUFFER_BINDING reflects bindful state",
                                draw_indirect_buffer_binding == (GLint)dsa_vbo) ||
                    expect_true("GL_DISPATCH_INDIRECT_BUFFER_BINDING reflects bindful state",
                                dispatch_indirect_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("GL_UNIFORM_BUFFER_BINDING reflects indexed bind-base state",
                                uniform_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("GL_TRANSFORM_FEEDBACK_BUFFER_BINDING reflects indexed bind-range state",
                                transform_feedback_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("GL_ATOMIC_COUNTER_BUFFER_BINDING reflects indexed bind-base state",
                                atomic_counter_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("GL_SHADER_STORAGE_BUFFER_BINDING reflects indexed bind-range state",
                                shader_storage_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("glGetIntegeri_v reports indexed uniform binding",
                                indexed_uniform_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("glGetIntegeri_v reports indexed transform-feedback binding",
                                indexed_transform_feedback_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("glGetIntegeri_v reports indexed atomic-counter binding",
                                indexed_atomic_counter_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("glGetIntegeri_v reports indexed shader-storage binding",
                                indexed_shader_storage_buffer_binding == (GLint)dsa_immutable_vbo) ||
                    expect_true("glGetInteger64i_v reports indexed uniform full-range state",
                                indexed_uniform_buffer_start64 == 0 &&
                                indexed_uniform_buffer_size64 ==
                                    (GLint64)sizeof(mapped_storage_triangle_vertices)) ||
                    expect_true("glGetInteger64i_v reports indexed transform-feedback range state",
                                indexed_transform_feedback_buffer_start64 == 8 &&
                                indexed_transform_feedback_buffer_size64 == 24) ||
                    expect_true("glGetInteger64i_v reports indexed atomic-counter full-range state",
                                indexed_atomic_counter_buffer_start64 == 0 &&
                                indexed_atomic_counter_buffer_size64 ==
                                    (GLint64)sizeof(mapped_storage_triangle_vertices)) ||
                    expect_true("glGetInteger64i_v reports indexed shader-storage range state",
                                indexed_shader_storage_buffer_start64 == 0 &&
                                indexed_shader_storage_buffer_size64 == 32) ||
                    expect_true("glGetBufferParameteri64v reports the generic uniform buffer size",
                                bound_uniform_buffer_size64 ==
                                    (GLint64)sizeof(mapped_storage_triangle_vertices)) ||
                    expect_true("glGetNamedBufferParameteri64v reports named immutable size",
                                named_buffer_size64 ==
                                    (GLint64)sizeof(mapped_storage_triangle_vertices)) ||
                    expect_true("glGetNamedBufferParameteri64v reports named storage flags",
                                named_buffer_storage_flags64 == (GLint64)named_storage_flags) ||
                    expect_true("GL_MAX_TRANSFORM_FEEDBACK_BUFFERS is nonzero",
                                max_transform_feedback_buffers > 0) ||
                    expect_true("GL_MAX_UNIFORM_BUFFER_BINDINGS covers queried index",
                                max_uniform_buffer_bindings > 1) ||
                    expect_true("GL_MAX_ATOMIC_COUNTER_BUFFER_BINDINGS covers queried index",
                                max_atomic_counter_buffer_bindings > 3) ||
                    expect_true("GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS covers queried index",
                                max_shader_storage_buffer_bindings > 2) ||
                    expect_true("GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT is nonzero",
                                uniform_buffer_offset_alignment > 0) ||
                    expect_true("GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT is nonzero",
                                shader_storage_buffer_offset_alignment > 0)) {
                    AO46SetCurrentContext(NULL);
                    AO46DestroyContext(copy_ctx);
                    AO46DestroyContext(ctx);
                    AO46DestroyPixelFormat(pix);
                    return 1;
                }
            }
        }

        {
            static const GLchar *textured_vertex_shader_source =
                "#version 150 core\n"
                "in vec2 position;\n"
                "in vec4 color;\n"
                "in vec2 texCoord;\n"
                "out vec4 vertexColor;\n"
                "out vec2 uv;\n"
                "void main(void)\n"
                "{\n"
                "    vertexColor = color;\n"
                "    uv = texCoord;\n"
                "    gl_Position = vec4(position, 0.0, 1.0);\n"
                "}\n";
            static const GLchar *textured_fragment_shader_source =
                "#version 150 core\n"
                "in vec4 vertexColor;\n"
                "in vec2 uv;\n"
                "uniform sampler2D tex;\n"
                "out vec4 fragColor;\n"
                "void main(void)\n"
                "{\n"
                "    fragColor = texture(tex, uv) * vertexColor;\n"
                "}\n";
            static const GLfloat textured_vertices[] = {
                -0.6f, -0.6f, 1.0f, 1.0f, 1.0f, 1.0f, 0.0f, 0.0f,
                 0.6f, -0.6f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0.0f,
                 0.0f,  0.6f, 1.0f, 1.0f, 1.0f, 1.0f, 0.5f, 1.0f
            };
            static const GLubyte uploaded_texture[] = {
                255, 255,   0, 255,
                255, 255,   0, 255,
                255, 255,   0, 255,
                255, 255,   0, 255
            };
            static const GLubyte aligned_texture_upload[] = {
                255,   0,   0, 255, 0, 0, 0, 0,
                  0, 255,   0, 255, 0, 0, 0, 0
            };
            static const GLubyte aligned_texture_sub_upload[] = {
                  0,   0, 255, 255, 0, 0, 0, 0
            };
            static const GLubyte mipmap_level0_upload[] = {
                255,   0,   0, 255, 255,   0,   0, 255,   0, 255,   0, 255,   0, 255,   0, 255,
                255,   0,   0, 255, 255,   0,   0, 255,   0, 255,   0, 255,   0, 255,   0, 255,
                  0,   0, 255, 255,   0,   0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
                  0,   0, 255, 255,   0,   0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
            };
            GLuint mipmap_texture = 0;
            GLint immutable_format = 0;
            GLint immutable_levels = 0;
            GLint mipmap_level1_width = 0;
            GLint mipmap_level1_height = 0;
            GLint mipmap_level2_width = 0;
            GLint mipmap_level2_height = 0;
            GLubyte mipmap_level1_readback[16] = { 0 };
            GLubyte mipmap_level2_readback[4] = { 0 };
            GLubyte mipmap_sampled_pixel[4] = { 0 };

            glGetIntegerv(GL_ACTIVE_TEXTURE, &active_texture);
            glGetIntegerv(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &max_texture_units);
            glGenTextures(1, &texture);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, texture);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture_binding_2d);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &texture_min_filter);
            glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &texture_mag_filter);
            glTexImage2D(GL_TEXTURE_2D,
                         0,
                         GL_RGBA8,
                         2,
                         2,
                         0,
                         GL_RGBA,
                         GL_UNSIGNED_BYTE,
                         uploaded_texture);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &texture_width);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &texture_height);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &texture_internal_format);
            glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, uploaded_texture_readback);
            if (expect_true("glGenTextures produced texture name", texture != 0) ||
                expect_true("active texture defaults to GL_TEXTURE0", active_texture == GL_TEXTURE0) ||
                expect_true("GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS reports usable count", max_texture_units >= 1) ||
                expect_true("glIsTexture(texture) after bind", glIsTexture(texture) == GL_TRUE) ||
                expect_true("GL_TEXTURE_BINDING_2D reflects bound texture", texture_binding_2d == (GLint)texture) ||
                expect_true("GL_TEXTURE_MIN_FILTER round-trips", texture_min_filter == GL_NEAREST) ||
                expect_true("GL_TEXTURE_MAG_FILTER round-trips", texture_mag_filter == GL_NEAREST) ||
                expect_true("GL_TEXTURE_WIDTH reflects upload", texture_width == 2) ||
                expect_true("GL_TEXTURE_HEIGHT reflects upload", texture_height == 2) ||
                expect_true("GL_TEXTURE_INTERNAL_FORMAT reflects upload", texture_internal_format == GL_RGBA8) ||
                expect_true("glGetTexImage readback matches uploaded texel",
                            uploaded_texture_readback[0] == 255 &&
                            uploaded_texture_readback[1] == 255 &&
                            uploaded_texture_readback[2] == 0 &&
                            uploaded_texture_readback[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glGenTextures(1, &aligned_texture);
            glBindTexture(GL_TEXTURE_2D, aligned_texture);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 8);
            glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpack_alignment);
            glTexImage2D(GL_TEXTURE_2D,
                         0,
                         GL_RGBA8,
                         1,
                         2,
                         0,
                         GL_RGBA,
                         GL_UNSIGNED_BYTE,
                         aligned_texture_upload);
            glTexSubImage2D(GL_TEXTURE_2D,
                            0,
                            0,
                            1,
                            1,
                            1,
                            GL_RGBA,
                            GL_UNSIGNED_BYTE,
                            aligned_texture_sub_upload);
            glPixelStorei(GL_PACK_ALIGNMENT, 8);
            glGetIntegerv(GL_PACK_ALIGNMENT, &pack_alignment);
            memset(aligned_texture_readback, 0, sizeof(aligned_texture_readback));
            glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, aligned_texture_readback);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            glPixelStorei(GL_PACK_ALIGNMENT, 4);
            if (expect_true("glGenTextures produced aligned upload texture", aligned_texture != 0) ||
                expect_true("GL_UNPACK_ALIGNMENT round-trips", unpack_alignment == 8) ||
                expect_true("GL_PACK_ALIGNMENT round-trips", pack_alignment == 8) ||
                expect_true("aligned texture first row preserved",
                            aligned_texture_readback[0] == 255 &&
                            aligned_texture_readback[1] == 0 &&
                            aligned_texture_readback[2] == 0 &&
                            aligned_texture_readback[3] == 255) ||
                expect_true("aligned texture second row replaced by glTexSubImage2D",
                            aligned_texture_readback[8] == 0 &&
                            aligned_texture_readback[9] == 0 &&
                            aligned_texture_readback[10] == 255 &&
                            aligned_texture_readback[11] == 255) ||
                expect_true("pack alignment preserves row padding bytes",
                            aligned_texture_readback[4] == 0 &&
                            aligned_texture_readback[5] == 0 &&
                            aligned_texture_readback[6] == 0 &&
                            aligned_texture_readback[7] == 0 &&
                            aligned_texture_readback[12] == 0 &&
                            aligned_texture_readback[13] == 0 &&
                            aligned_texture_readback[14] == 0 &&
                            aligned_texture_readback[15] == 0) ||
                expect_true("aligned texture path leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }
            glDeleteTextures(1, &aligned_texture);
            glBindTexture(GL_TEXTURE_2D, texture);

            glGenTextures(1, &mipmap_texture);
            glBindTexture(GL_TEXTURE_2D, mipmap_texture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (GLfloat)GL_NEAREST);
            if (have_texture_storage) {
                glTexStorage2D(GL_TEXTURE_2D, 3, GL_RGBA8, 4, 4);
                glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_IMMUTABLE_FORMAT, &immutable_format);
                glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_IMMUTABLE_LEVELS, &immutable_levels);
            } else {
                immutable_format = 0;
                immutable_levels = 0;
                glTexImage2D(GL_TEXTURE_2D,
                             0,
                             GL_RGBA8,
                             4,
                             4,
                             0,
                             GL_RGBA,
                             GL_UNSIGNED_BYTE,
                             NULL);
            }
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 1, GL_TEXTURE_WIDTH, &mipmap_level1_width);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 1, GL_TEXTURE_HEIGHT, &mipmap_level1_height);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 2, GL_TEXTURE_WIDTH, &mipmap_level2_width);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 2, GL_TEXTURE_HEIGHT, &mipmap_level2_height);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, mipmap_level0_upload);
            glGenerateMipmap(GL_TEXTURE_2D);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 1, GL_TEXTURE_WIDTH, &mipmap_level1_width);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 1, GL_TEXTURE_HEIGHT, &mipmap_level1_height);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 2, GL_TEXTURE_WIDTH, &mipmap_level2_width);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 2, GL_TEXTURE_HEIGHT, &mipmap_level2_height);
            glGetTexImage(GL_TEXTURE_2D, 1, GL_RGBA, GL_UNSIGNED_BYTE, mipmap_level1_readback);
            glGetTexImage(GL_TEXTURE_2D, 2, GL_RGBA, GL_UNSIGNED_BYTE, mipmap_level2_readback);
            if (expect_true("glGenTextures produced mipmap texture", mipmap_texture != 0) ||
                expect_true("texture allocation path leaves no GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("immutable texture state matches storage support",
                            have_texture_storage ?
                                (immutable_format == GL_TRUE && immutable_levels == 3) :
                                (immutable_format == 0 && immutable_levels == 0)) ||
                expect_true("mipmap level 1 dimensions are 2x2",
                            mipmap_level1_width == 2 && mipmap_level1_height == 2) ||
                expect_true("mipmap level 2 dimensions are 1x1",
                            mipmap_level2_width == 1 && mipmap_level2_height == 1) ||
                expect_true("generated mip level 1 top-left texel is red",
                            mipmap_level1_readback[0] == 255 &&
                            mipmap_level1_readback[1] == 0 &&
                            mipmap_level1_readback[2] == 0 &&
                            mipmap_level1_readback[3] == 255) ||
                expect_true("generated mip level 1 bottom-right texel is white",
                            mipmap_level1_readback[12] == 255 &&
                            mipmap_level1_readback[13] == 255 &&
                            mipmap_level1_readback[14] == 255 &&
                            mipmap_level1_readback[15] == 255) ||
                expect_true("generated mip level 2 averages the quadrant colors",
                            mipmap_level2_readback[0] == 128 &&
                            mipmap_level2_readback[1] == 128 &&
                            mipmap_level2_readback[2] == 128 &&
                            mipmap_level2_readback[3] == 255) ||
                expect_true("mipmap generation path leaves no GL error", glGetError() == GL_NO_ERROR)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }
            glBindTexture(GL_TEXTURE_2D, texture);

            textured_vertex_shader = glCreateShader(GL_VERTEX_SHADER);
            textured_fragment_shader = glCreateShader(GL_FRAGMENT_SHADER);
            textured_program = glCreateProgram();
            glShaderSource(textured_vertex_shader, 1, &textured_vertex_shader_source, NULL);
            glCompileShader(textured_vertex_shader);
            glGetShaderiv(textured_vertex_shader, GL_COMPILE_STATUS, &compile_status);
            glShaderSource(textured_fragment_shader, 1, &textured_fragment_shader_source, NULL);
            glCompileShader(textured_fragment_shader);
            glGetShaderiv(textured_fragment_shader, GL_COMPILE_STATUS, &textured_fragment_compile_status);
            glAttachShader(textured_program, textured_vertex_shader);
            glAttachShader(textured_program, textured_fragment_shader);
            glBindAttribLocation(textured_program, 0, "position");
            glBindAttribLocation(textured_program, 1, "color");
            glBindAttribLocation(textured_program, 2, "texCoord");
            glLinkProgram(textured_program);
            glValidateProgram(textured_program);
            glGetProgramiv(textured_program, GL_LINK_STATUS, &link_status);
            glGetProgramiv(textured_program, GL_VALIDATE_STATUS, &validate_status);
            glGetProgramiv(textured_program, GL_ACTIVE_ATTRIBUTES, &active_attribute_count);
            glGetProgramiv(textured_program, GL_ACTIVE_UNIFORMS, &active_uniform_count);
            texcoord_location = glGetAttribLocation(textured_program, "texCoord");
            texture_uniform_location = glGetUniformLocation(textured_program, "tex");
            if (expect_true("textured vertex shader compiles", compile_status == GL_TRUE) ||
                expect_true("textured fragment shader compiles", textured_fragment_compile_status == GL_TRUE) ||
                expect_true("textured program links", link_status == GL_TRUE) ||
                expect_true("textured program validates", validate_status == GL_TRUE) ||
                expect_true("textured program exposes texcoord attribute", texcoord_location == 2) ||
                expect_true("textured program reports active attributes", active_attribute_count == 3) ||
                expect_true("textured program reports active uniform", active_uniform_count == 1) ||
                expect_true("textured sampler uniform is addressable", texture_uniform_location == 0)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glGenBuffers(1, &textured_vbo);
            glBindBuffer(GL_ARRAY_BUFFER, textured_vbo);
            glBufferData(GL_ARRAY_BUFFER, sizeof(textured_vertices), textured_vertices, GL_STATIC_DRAW);
            glGenVertexArrays(1, &textured_vao);
            glBindVertexArray(textured_vao);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8 * (GLsizei)sizeof(GLfloat), (const void *)0);
            glEnableVertexAttribArray(1);
            glVertexAttribPointer(1,
                                  4,
                                  GL_FLOAT,
                                  GL_FALSE,
                                  8 * (GLsizei)sizeof(GLfloat),
                                  (const void *)(2 * sizeof(GLfloat)));
            glEnableVertexAttribArray(2);
            glVertexAttribPointer(2,
                                  2,
                                  GL_FLOAT,
                                  GL_FALSE,
                                  8 * (GLsizei)sizeof(GLfloat),
                                  (const void *)(6 * sizeof(GLfloat)));
            glUseProgram(textured_program);
            glUniform1i(texture_uniform_location, 0);
            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, textured_pixel);
            glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, background_pixel);
            if (expect_true("textured triangle draw completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("textured triangle center pixel is sampled from texture",
                            textured_pixel[0] == 255 &&
                            textured_pixel[1] == 255 &&
                            textured_pixel[2] == 0 &&
                            textured_pixel[3] == 255) ||
                expect_true("textured background pixel remains cleared",
                            background_pixel[0] == 0 &&
                            background_pixel[1] == 0 &&
                            background_pixel[2] == 0 &&
                            background_pixel[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glGenerateMipmap(GL_TEXTURE_2D);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_LINEAR);
            glClear(GL_COLOR_BUFFER_BIT);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glReadPixels(16, 16, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, mipmap_sampled_pixel);
            if (expect_true("mip-filtered textured draw completes without GL error", glGetError() == GL_NO_ERROR) ||
                expect_true("mip-filtered textured triangle still samples generated texels",
                            mipmap_sampled_pixel[0] == 255 &&
                            mipmap_sampled_pixel[1] == 255 &&
                            mipmap_sampled_pixel[2] == 0 &&
                            mipmap_sampled_pixel[3] == 255)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }

            glDeleteVertexArrays(1, &textured_vao);
            glDeleteBuffers(1, &textured_vbo);
            glDeleteShader(textured_vertex_shader);
            glDeleteShader(textured_fragment_shader);
            glUseProgram(0);
            glDeleteProgram(textured_program);
            glDeleteTextures(1, &mipmap_texture);
            glDeleteTextures(1, &texture);
            if (expect_true("glIsVertexArray(textured_vao) clears after delete", glIsVertexArray(textured_vao) == GL_FALSE) ||
                expect_true("glIsBuffer(textured_vbo) clears after delete", glIsBuffer(textured_vbo) == GL_FALSE) ||
                expect_true("glIsProgram(textured_program) clears after delete", glIsProgram(textured_program) == GL_FALSE) ||
                expect_true("glIsTexture(aligned_texture) clears after delete", glIsTexture(aligned_texture) == GL_FALSE) ||
                expect_true("glIsTexture(mipmap_texture) clears after delete", glIsTexture(mipmap_texture) == GL_FALSE) ||
                expect_true("glIsTexture(texture) clears after delete", glIsTexture(texture) == GL_FALSE)) {
                AO46SetCurrentContext(NULL);
                AO46DestroyContext(copy_ctx);
                AO46DestroyContext(ctx);
                AO46DestroyPixelFormat(pix);
                return 1;
            }
        }

        glDeleteVertexArrays(1, &vao);
        glDeleteBuffers(1, &dsa_immutable_vbo);
        glDeleteBuffers(1, &dsa_vbo);
        glDeleteBuffers(1, &copy_vbo);
        glDeleteBuffers(1, &ebo);
        glDeleteBuffers(1, &vbo);
        glDeleteShader(vertex_shader);
        glDeleteShader(fragment_shader);
        glGetShaderiv(vertex_shader, GL_DELETE_STATUS, &delete_status);
        glDeleteProgram(program);
        if (expect_true("shader delete status reflects pending deletion", delete_status == GL_TRUE) ||
            expect_true("glIsVertexArray(vao) clears after delete", glIsVertexArray(vao) == GL_FALSE) ||
            expect_true("glIsBuffer(dsa_immutable_vbo) clears after delete",
                        glIsBuffer(dsa_immutable_vbo) == GL_FALSE) ||
            expect_true("glIsBuffer(dsa_vbo) clears after delete", glIsBuffer(dsa_vbo) == GL_FALSE) ||
            expect_true("glIsBuffer(copy_vbo) clears after delete", glIsBuffer(copy_vbo) == GL_FALSE) ||
            expect_true("glIsBuffer(ebo) clears after delete", glIsBuffer(ebo) == GL_FALSE) ||
            expect_true("glIsBuffer(vbo) clears after delete", glIsBuffer(vbo) == GL_FALSE) ||
            expect_true("glIsProgram(program) clears after delete", glIsProgram(program) == GL_FALSE) ||
            expect_true("glIsShader(vertex) clears after final delete", glIsShader(vertex_shader) == GL_FALSE) ||
            expect_true("glIsShader(fragment) clears after final delete", glIsShader(fragment_shader) == GL_FALSE) ||
            expect_true("delete path leaves no GL error", glGetError() == GL_NO_ERROR)) {
            AO46SetCurrentContext(NULL);
            AO46DestroyContext(copy_ctx);
            AO46DestroyContext(ctx);
            AO46DestroyPixelFormat(pix);
            return 1;
        }
    }

    if (expect_no_error("AO46SetCurrentContext(NULL) after GL checks)", AO46SetCurrentContext(NULL))) {
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46CreatePBuffer",
                        AO46CreatePBuffer(32, 32, GL_TEXTURE_2D, GL_RGBA8, 4, &pbuffer)) ||
        expect_true("pbuffer exists", pbuffer != NULL) ||
        expect_no_error("AO46DescribePBuffer",
                        AO46DescribePBuffer(pbuffer,
                                            &pbuffer_width,
                                            &pbuffer_height,
                                            &pbuffer_target,
                                            &pbuffer_internal_format,
                                            &pbuffer_mipmap)) ||
        expect_true("pbuffer width round-trip", pbuffer_width == 32) ||
        expect_true("pbuffer height round-trip", pbuffer_height == 32) ||
        expect_true("pbuffer target round-trip", pbuffer_target == GL_TEXTURE_2D) ||
        expect_true("pbuffer internal format round-trip", pbuffer_internal_format == GL_RGBA8) ||
        expect_true("pbuffer mipmap round-trip", pbuffer_mipmap == 4) ||
        expect_no_error("AO46SetPBuffer",
                        AO46SetPBuffer(ctx, pbuffer, GL_TEXTURE_2D, 2, 0)) ||
        expect_no_error("AO46GetPBuffer",
                        AO46GetPBuffer(ctx, &bound_pbuffer, &pbuffer_face, &pbuffer_level, &pbuffer_screen)) ||
        expect_true("bound pbuffer matches", bound_pbuffer == pbuffer) ||
        expect_true("bound pbuffer face round-trip", pbuffer_face == GL_TEXTURE_2D) ||
        expect_true("bound pbuffer level round-trip", pbuffer_level == 2) ||
        expect_true("bound pbuffer screen round-trip", pbuffer_screen == 0) ||
        expect_no_error("AO46TexImagePBuffer",
                        AO46TexImagePBuffer(ctx, pbuffer, GL_FRONT))) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetCurrentContext(ctx for pbuffer import)", AO46SetCurrentContext(ctx))) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    glClearColor(0.0f, 0.75f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glGenTextures(1, &pbuffer_texture);
    glBindTexture(GL_TEXTURE_2D, pbuffer_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    if (expect_true("glGenTextures produced pbuffer import texture", pbuffer_texture != 0) ||
        expect_true("glIsTexture(pbuffer_texture) after bind", glIsTexture(pbuffer_texture) == GL_TRUE) ||
        expect_no_error("AO46TexImagePBuffer(import)",
                        AO46TexImagePBuffer(ctx, pbuffer, GL_FRONT))) {
        AO46SetCurrentContext(NULL);
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &texture_width);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &texture_height);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, triangle_storage);
    memcpy(pbuffer_texture_pixel, triangle_storage, sizeof(pbuffer_texture_pixel));
    glDeleteTextures(1, &pbuffer_texture);
    if (expect_true("pbuffer import defines texture width from attached mip image", texture_width == 8) ||
        expect_true("pbuffer import defines texture height from attached mip image", texture_height == 8) ||
        expect_true("pbuffer import copies drawable color into texture",
                    pbuffer_texture_pixel[0] == 0 &&
                    pbuffer_texture_pixel[1] == 191 &&
                    pbuffer_texture_pixel[2] == 0 &&
                    pbuffer_texture_pixel[3] == 255) ||
        expect_true("glIsTexture(pbuffer_texture) clears after delete", glIsTexture(pbuffer_texture) == GL_FALSE) ||
        expect_true("pbuffer texture import leaves no GL error", glGetError() == GL_NO_ERROR) ||
        expect_no_error("AO46SetCurrentContext(NULL) after pbuffer import", AO46SetCurrentContext(NULL))) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetFullScreenOnDisplay", AO46SetFullScreenOnDisplay(ctx, 0x1)) ||
        expect_no_error("AO46GetVirtualScreen(after fullscreen)", AO46GetVirtualScreen(ctx, &screen)) ||
        expect_true("fullscreen virtual screen reset", screen == 0)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetVirtualScreen", AO46SetVirtualScreen(ctx, 2)) ||
        expect_no_error("AO46GetVirtualScreen", AO46GetVirtualScreen(ctx, &screen)) ||
        expect_true("virtual screen round-trip", screen == 2)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetContextParameter(copy source swap interval)",
                        AO46SetContextParameter(ctx, kCGLCPSwapInterval, &swap_interval))) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetContextParameter(swap rectangle)",
                        AO46SetContextParameter(ctx, kCGLCPSwapRectangle, swap_rectangle)) ||
        expect_no_error("AO46GetContextParameter(swap rectangle)",
                        AO46GetContextParameter(ctx, kCGLCPSwapRectangle, swap_rectangle_out)) ||
        expect_true("swap rectangle round-trip",
                    memcmp(swap_rectangle, swap_rectangle_out, sizeof(swap_rectangle)) == 0) ||
        expect_no_error("AO46SetContextParameter(backing size)",
                        AO46SetContextParameter(ctx, kCGLCPSurfaceBackingSize, backing_size)) ||
        expect_no_error("AO46GetContextParameter(backing size)",
                        AO46GetContextParameter(ctx, kCGLCPSurfaceBackingSize, backing_size_out)) ||
        expect_true("backing size round-trip",
                    memcmp(backing_size, backing_size_out, sizeof(backing_size)) == 0) ||
        expect_no_error("AO46GetContextParameter(renderer id)",
                        AO46GetContextParameter(ctx, kCGLCPCurrentRendererID, &renderer_id)) ||
        expect_true("renderer id present", renderer_id == 0x414F3436)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46CopyContext", AO46CopyContext(ctx, copy_ctx, (GLbitfield)~0u)) ||
        expect_no_error("AO46GetContextParameter(copy swap interval)",
                        AO46GetContextParameter(copy_ctx, kCGLCPSwapInterval, &value)) ||
        expect_true("copied swap interval", value == swap_interval) ||
        expect_no_error("AO46GetVirtualScreen(copy)", AO46GetVirtualScreen(copy_ctx, &screen)) ||
        expect_true("copied virtual screen", screen == 2)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46CreateContext(shared)", AO46CreateContext(pix, ctx, &shared_ctx)) ||
        expect_true("shared context exists", shared_ctx != NULL) ||
        expect_no_error("AO46CreateContext(independent)", AO46CreateContext(pix, NULL, &independent_ctx)) ||
        expect_true("independent context exists", independent_ctx != NULL)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(shared_ctx);
        AO46DestroyContext(independent_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    ctx_group = AO46GetShareGroupForContext(ctx);
    shared_group = AO46GetShareGroupForContext(shared_ctx);
    independent_group = AO46GetShareGroupForContext(independent_ctx);
    if (expect_true("primary context share group exists", ctx_group != NULL) ||
        expect_true("shared context uses same share group", ctx_group == shared_group) ||
        expect_true("independent context gets separate share group", ctx_group != independent_group)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(shared_ctx);
        AO46DestroyContext(independent_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46CreateHeadlessDrawable", AO46CreateHeadlessDrawable(ctx)) ||
        expect_true("drawable kind is headless",
                    AO46GetDrawableKind(ctx) == AO46DrawableKindHeadless) ||
        expect_no_error("AO46GetContextParameter(has drawable)",
                        AO46GetContextParameter(ctx, kCGLCPHasDrawable, &value)) ||
        expect_true("drawable attached", value == 1) ||
        expect_no_error("AO46UpdateContext", AO46UpdateContext(ctx)) ||
        expect_no_error("AO46FlushDrawable", AO46FlushDrawable(ctx)) ||
        expect_no_error("AO46ClearDrawable", AO46ClearDrawable(ctx)) ||
        expect_true("drawable cleared", AO46GetDrawableKind(ctx) == AO46DrawableKindNone)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(shared_ctx);
        AO46DestroyContext(independent_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    if (expect_no_error("AO46SetCurrentContext", AO46SetCurrentContext(ctx)) ||
        expect_true("current context round-trip", AO46GetCurrentContext() == ctx) ||
        expect_no_error("AO46SetCurrentContext(NULL)", AO46SetCurrentContext(NULL)) ||
        expect_true("current context cleared", AO46GetCurrentContext() == NULL)) {
        AO46DestroyPBuffer(pbuffer);
        AO46DestroyContext(copy_ctx);
        AO46DestroyContext(shared_ctx);
        AO46DestroyContext(independent_ctx);
        AO46DestroyContext(ctx);
        AO46DestroyPixelFormat(pix);
        return 1;
    }

    AO46DestroyPBuffer(pbuffer);
    AO46DestroyContext(copy_ctx);
    AO46DestroyContext(shared_ctx);
    AO46DestroyContext(independent_ctx);
    AO46DestroyContext(ctx);
    AO46DestroyPixelFormat(pix);
    puts("AO46 runtime compatibility smoke passed");
    return 0;
}

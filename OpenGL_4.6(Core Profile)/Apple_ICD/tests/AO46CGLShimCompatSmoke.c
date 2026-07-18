#include <OpenGL/OpenGL.h>

#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>

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

typedef struct {
    void *handle;
    CGLError (*choose_pixel_format)(const CGLPixelFormatAttribute *, CGLPixelFormatObj *, GLint *);
    CGLError (*destroy_pixel_format)(CGLPixelFormatObj);
    CGLError (*create_context)(CGLPixelFormatObj, CGLContextObj, CGLContextObj *);
    CGLError (*destroy_context)(CGLContextObj);
    CGLShareGroupObj (*get_share_group)(CGLContextObj);
    CGLError (*set_current_context)(CGLContextObj);
    CGLContextObj (*get_current_context)(void);
} AO46ShimDispatch;

static int load_shim_dispatch(AO46ShimDispatch *dispatch)
{
    const char *shim_path = getenv("AO46_SHIM_PATH");

    if (!dispatch || !shim_path || shim_path[0] == '\0') {
        fprintf(stderr, "AO46_SHIM_PATH is not set\n");
        return 1;
    }

    dispatch->handle = dlopen(shim_path, RTLD_NOW | RTLD_LOCAL);
    if (!dispatch->handle) {
        fprintf(stderr, "failed to load shim %s: %s\n", shim_path, dlerror());
        return 1;
    }

    dispatch->choose_pixel_format = dlsym(dispatch->handle, "CGLChoosePixelFormat");
    dispatch->destroy_pixel_format = dlsym(dispatch->handle, "CGLDestroyPixelFormat");
    dispatch->create_context = dlsym(dispatch->handle, "CGLCreateContext");
    dispatch->destroy_context = dlsym(dispatch->handle, "CGLDestroyContext");
    dispatch->get_share_group = dlsym(dispatch->handle, "CGLGetShareGroup");
    dispatch->set_current_context = dlsym(dispatch->handle, "CGLSetCurrentContext");
    dispatch->get_current_context = dlsym(dispatch->handle, "CGLGetCurrentContext");

    if (!dispatch->choose_pixel_format ||
        !dispatch->destroy_pixel_format ||
        !dispatch->create_context ||
        !dispatch->destroy_context ||
        !dispatch->get_share_group ||
        !dispatch->set_current_context ||
        !dispatch->get_current_context) {
        fprintf(stderr, "shim is missing one or more required CGL symbols\n");
        dlclose(dispatch->handle);
        *dispatch = (AO46ShimDispatch){ 0 };
        return 1;
    }

    return 0;
}

int main(void)
{
    const CGLPixelFormatAttribute attribs[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_GL3_Core,
        0
    };
    CGLPixelFormatObj pix = NULL;
    CGLContextObj primary = NULL;
    CGLContextObj shared = NULL;
    CGLContextObj standalone = NULL;
    CGLShareGroupObj primary_group = NULL;
    CGLShareGroupObj shared_group = NULL;
    CGLShareGroupObj standalone_group = NULL;
    GLint npix = 0;
    AO46ShimDispatch dispatch = { 0 };

    if (load_shim_dispatch(&dispatch) != 0) {
        return 1;
    }

    if (expect_no_error("CGLChoosePixelFormat", dispatch.choose_pixel_format(attribs, &pix, &npix)) ||
        expect_true("CGL pixel format exists", pix != NULL) ||
        expect_true("exactly one CGL pixel format", npix == 1)) {
        dlclose(dispatch.handle);
        return 1;
    }

    if (expect_no_error("CGLCreateContext(primary)", dispatch.create_context(pix, NULL, &primary)) ||
        expect_true("primary context exists", primary != NULL) ||
        expect_no_error("CGLCreateContext(shared)", dispatch.create_context(pix, primary, &shared)) ||
        expect_true("shared context exists", shared != NULL) ||
        expect_no_error("CGLCreateContext(standalone)", dispatch.create_context(pix, NULL, &standalone)) ||
        expect_true("standalone context exists", standalone != NULL)) {
        dispatch.destroy_context(standalone);
        dispatch.destroy_context(shared);
        dispatch.destroy_context(primary);
        dispatch.destroy_pixel_format(pix);
        dlclose(dispatch.handle);
        return 1;
    }

    primary_group = dispatch.get_share_group(primary);
    shared_group = dispatch.get_share_group(shared);
    standalone_group = dispatch.get_share_group(standalone);
    if (expect_true("primary share group exists", primary_group != NULL) ||
        expect_true("shared context reuses share group", primary_group == shared_group) ||
        expect_true("standalone context gets separate share group", primary_group != standalone_group)) {
        dispatch.destroy_context(standalone);
        dispatch.destroy_context(shared);
        dispatch.destroy_context(primary);
        dispatch.destroy_pixel_format(pix);
        dlclose(dispatch.handle);
        return 1;
    }

    if (expect_no_error("CGLSetCurrentContext(shared)", dispatch.set_current_context(shared)) ||
        expect_true("CGL current context round-trip", dispatch.get_current_context() == shared) ||
        expect_no_error("CGLSetCurrentContext(NULL)", dispatch.set_current_context(NULL)) ||
        expect_true("CGL current context cleared", dispatch.get_current_context() == NULL)) {
        dispatch.destroy_context(standalone);
        dispatch.destroy_context(shared);
        dispatch.destroy_context(primary);
        dispatch.destroy_pixel_format(pix);
        dlclose(dispatch.handle);
        return 1;
    }

    dispatch.destroy_context(standalone);
    dispatch.destroy_context(shared);
    dispatch.destroy_context(primary);
    dispatch.destroy_pixel_format(pix);
    dlclose(dispatch.handle);
    puts("AO46 CGL shim compatibility smoke passed");
    return 0;
}

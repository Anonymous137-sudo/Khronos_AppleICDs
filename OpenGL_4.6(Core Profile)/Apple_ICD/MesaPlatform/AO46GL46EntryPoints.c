#include "GL/gl.h"
#include "GL/glext.h"

extern void *_mesa_glapi_get_proc_address(const char *name);

typedef void (APIENTRYP ao46_multi_draw_arrays_indirect_count_proc)(
    GLenum mode, const void *indirect, GLintptr drawcount,
    GLsizei maxdrawcount, GLsizei stride);
typedef void (APIENTRYP ao46_multi_draw_elements_indirect_count_proc)(
    GLenum mode, GLenum type, const void *indirect, GLintptr drawcount,
    GLsizei maxdrawcount, GLsizei stride);

static ao46_multi_draw_arrays_indirect_count_proc
ao46_get_multi_draw_arrays_indirect_count(void)
{
    return (ao46_multi_draw_arrays_indirect_count_proc)
        _mesa_glapi_get_proc_address("glMultiDrawArraysIndirectCountARB");
}

static ao46_multi_draw_elements_indirect_count_proc
ao46_get_multi_draw_elements_indirect_count(void)
{
    return (ao46_multi_draw_elements_indirect_count_proc)
        _mesa_glapi_get_proc_address("glMultiDrawElementsIndirectCountARB");
}

void APIENTRY
glMultiDrawArraysIndirectCount(GLenum mode, const void *indirect,
                               GLintptr drawcount, GLsizei maxdrawcount,
                               GLsizei stride)
{
    ao46_get_multi_draw_arrays_indirect_count()(
        mode, indirect, drawcount, maxdrawcount, stride);
}

void APIENTRY
glMultiDrawArraysIndirectCountARB(GLenum mode, const void *indirect,
                                  GLintptr drawcount, GLsizei maxdrawcount,
                                  GLsizei stride)
{
    ao46_get_multi_draw_arrays_indirect_count()(
        mode, indirect, drawcount, maxdrawcount, stride);
}

void APIENTRY
glMultiDrawElementsIndirectCount(GLenum mode, GLenum type,
                                 const void *indirect, GLintptr drawcount,
                                 GLsizei maxdrawcount, GLsizei stride)
{
    ao46_get_multi_draw_elements_indirect_count()(
        mode, type, indirect, drawcount, maxdrawcount, stride);
}

void APIENTRY
glMultiDrawElementsIndirectCountARB(GLenum mode, GLenum type,
                                    const void *indirect, GLintptr drawcount,
                                    GLsizei maxdrawcount, GLsizei stride)
{
    ao46_get_multi_draw_elements_indirect_count()(
        mode, type, indirect, drawcount, maxdrawcount, stride);
}

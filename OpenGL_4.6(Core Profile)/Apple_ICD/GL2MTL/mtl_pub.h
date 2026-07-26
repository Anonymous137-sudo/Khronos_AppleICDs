#ifndef AO46_METAL_PUBLIC_H
#define AO46_METAL_PUBLIC_H

#if defined(__APPLE__)
#  if defined(__has_include)
#    if __has_include(<OpenGL/CGLTypes.h>)
#      include <OpenGL/CGLTypes.h>
#    else
typedef int CGLError;
#    endif
#  else
#    include <OpenGL/CGLTypes.h>
#  endif
#else
typedef int CGLError;
#endif

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

struct pipe_screen;
struct pipe_context;
struct pipe_surface;
struct pipe_resource;

/* Metal global objects – accessible from all Metal files */
#ifdef __OBJC__
extern id<MTLDevice> g_mtl_device;
extern id<MTLCommandQueue> g_mtl_queue;
#endif

/* Screen creation */
struct pipe_screen *ao46_metal_screen_create(void);

/* Window surface creation and presentation */
CGLError ao46_metal_create_window_surface(struct pipe_context *pipe,
                                          void *window,
                                          struct pipe_resource **out_tex,
                                          struct pipe_surface **out_surf);
CGLError ao46_metal_present(struct pipe_context *pipe, struct pipe_surface *surf);

#endif /* AO46_METAL_PUBLIC_H */        
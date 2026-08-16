/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>

#include "AppleOpenGL46Runtime.h"

#include <stdio.h>

static int
fail(const char *label, CGLError error)
{
   fprintf(stderr, "%s failed with CGLError %d\n", label, error);
   return 1;
}

int
main(void)
{
   const CGLPixelFormatAttribute attributes[] = {
      kCGLPFAWindow,
      kCGLPFAOpenGLProfile,
      (CGLPixelFormatAttribute)kCGLOGLPVersion_GL3_Core,
      0,
   };
   AO46PixelFormatRef pixel_format = NULL;
   AO46ContextRef context = NULL;
   CAMetalLayer *layer;
   CAMetalLayer *display_p3_layer;
   GLint count = 0;
   GLint has_drawable = 0;
   GLint swap_interval = 0;
   CGLError error;

   @autoreleasepool {
      layer = [CAMetalLayer layer];
      layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
      layer.drawableSize = CGSizeMake(16, 16);
      display_p3_layer = [CAMetalLayer layer];
      display_p3_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
      display_p3_layer.drawableSize = CGSizeMake(16, 16);
      {
         CGColorSpaceRef display_p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);

         if (!display_p3)
            return fail("CGColorSpaceCreateWithName(Display P3)", kCGLBadContext);
         display_p3_layer.colorspace = display_p3;
         CGColorSpaceRelease(display_p3);
      }

      error = AO46ChoosePixelFormat(attributes, &pixel_format, &count);
      if (error != kCGLNoError || !pixel_format || count != 1)
         return fail("AO46ChoosePixelFormat(window)", error);

      error = AO46CreateContext(pixel_format, NULL, &context);
      if (error != kCGLNoError || !context) {
         AO46DestroyPixelFormat(pixel_format);
         return fail("AO46CreateContext(window)", error);
      }

      error = AO46AttachWindowToContext(context, (__bridge void *)display_p3_layer);
      if (error != kCGLBadDrawable) {
         AO46DestroyContext(context);
         AO46DestroyPixelFormat(pixel_format);
         return fail("AO46AttachWindowToContext(Display P3)", error);
      }

      error = AO46AttachWindowToContext(context, (__bridge void *)layer);
      if (error == kCGLNoError)
         error = AO46GetContextParameter(context, kCGLCPHasDrawable,
                                         &has_drawable);
      if (error == kCGLNoError && has_drawable != 1)
         error = kCGLBadDrawable;
      if (error == kCGLNoError)
         error = AO46SetContextParameter(context, kCGLCPSwapInterval,
                                         &swap_interval);
      if (error == kCGLNoError)
         error = AO46UpdateContext(context);
      if (error == kCGLNoError) {
         CGLError swap_error = AO46FlushDrawable(context);

         /* Swap prepares a new target after loss; retry without an explicit update. */
         if (swap_error == kCGLBadDrawable) {
            swap_error = AO46FlushDrawable(context);
            if (swap_error != kCGLNoError && swap_error != kCGLBadDrawable)
               error = swap_error;
         } else if (swap_error != kCGLNoError) {
            error = swap_error;
         }
      }
      if (error != kCGLNoError) {
         AO46DestroyContext(context);
         AO46DestroyPixelFormat(pixel_format);
         return fail("AO46 CAMetalLayer CGL lifecycle", error);
      }

      AO46ClearDrawable(context);
      AO46DestroyContext(context);
      AO46DestroyPixelFormat(pixel_format);
   }

   return 0;
}

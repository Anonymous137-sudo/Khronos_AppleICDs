/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 *
 * This is intentionally not a CTest: a success requires a live WindowServer.
 */

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include "AppleOpenGL46Runtime.h"

#include <stdio.h>

static int
fail(const char *label, CGLError error)
{
   fprintf(stderr, "%s failed with CGLError %d\n", label, error);
   return 1;
}

static void
pump_main_run_loop(NSTimeInterval seconds)
{
   NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

   while (deadline.timeIntervalSinceNow > 0) {
      @autoreleasepool {
         [[NSRunLoop mainRunLoop]
            runMode:NSDefaultRunLoopMode
         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
      }
   }
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
   NSWindow *window = nil;
   NSView *view = nil;
   CGLError error;
   GLint count = 0;
   GLint swap_interval = 1;
   bool current = false;

   @autoreleasepool {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

      window = [[NSWindow alloc]
         initWithContentRect:NSMakeRect(96, 96, 96, 96)
                   styleMask:NSWindowStyleMaskTitled
                     backing:NSBackingStoreBuffered
                       defer:NO];
      view = [[NSView alloc] initWithFrame:window.contentView.bounds];
      view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      view.wantsLayer = YES;
      {
         CAMetalLayer *layer = [CAMetalLayer layer];

         layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
         if (@available(macOS 10.15, *))
            layer.allowsNextDrawableTimeout = YES;
         view.layer = layer;
      }
      window.contentView = view;
      [window makeKeyAndOrderFront:nil];
      [NSApp activateIgnoringOtherApps:NO];
      pump_main_run_loop(0.1);

      error = AO46ChoosePixelFormat(attributes, &pixel_format, &count);
      if (error != kCGLNoError || !pixel_format || count != 1)
         return fail("AO46ChoosePixelFormat(window)", error);

      error = AO46CreateContext(pixel_format, NULL, &context);
      if (error == kCGLNoError)
         error = AO46AttachWindowToContext(context, (__bridge void *)view);
      if (error == kCGLNoError)
         error = AO46SetContextParameter(context, kCGLCPSwapInterval,
                                         &swap_interval);
      if (error == kCGLNoError)
         error = AO46SetCurrentContext(context);
      if (error == kCGLNoError)
         current = true;
      if (error == kCGLNoError) {
         glClearColor(0.125f, 0.5f, 0.875f, 1.0f);
         glClear(GL_COLOR_BUFFER_BIT);
         error = AO46FlushDrawable(context);
      }

      if (current)
         AO46SetCurrentContext(NULL);
      AO46ClearDrawable(context);
      AO46DestroyContext(context);
      AO46DestroyPixelFormat(pixel_format);
      [window orderOut:nil];
      [window close];

      if (error == kCGLBadDrawable) {
         fprintf(stderr,
                 "AO46 presentation smoke skipped: no compositor drawable\n");
         return 77;
      }
      if (error != kCGLNoError)
         return fail("AO46 visible CAMetalLayer present", error);
   }

   return 0;
}

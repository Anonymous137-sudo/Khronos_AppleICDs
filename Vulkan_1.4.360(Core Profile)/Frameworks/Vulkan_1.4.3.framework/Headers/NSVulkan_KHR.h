/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#import <AppKit/AppKit.h>

#include "CVK.h"

@class CAMetalLayer;

NS_ASSUME_NONNULL_BEGIN

/* The AppKit attachment state, not Vulkan surface or swapchain state. */
typedef NS_ENUM(NSUInteger, NSVulkanKHRSurfaceState) {
   NSVulkanKHRSurfaceStateDetached = 0,
   NSVulkanKHRSurfaceStateAttached = 1,
};

/*
 * A public AppKit lifecycle owner for the future Mesa WSI bridge. It has no
 * Vulkan object ownership and does not create a CAMetalLayer by itself.
 */
@interface NSVulkanKHRSurface : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithView:(nullable NSView *)view NS_DESIGNATED_INITIALIZER;

/* Mirrors NSOpenGLContext: attachment is non-owning and may disappear. */
@property(nonatomic, weak, nullable) NSView *view;
@property(nonatomic, readonly, nullable) CAMetalLayer *metalLayer;
@property(nonatomic, readonly) NSVulkanKHRSurfaceState state;
@property(nonatomic, readonly) CGSize drawableSize;
@property(nonatomic, readonly) CGFloat backingScaleFactor;
@property(nonatomic, readonly) NSUInteger generation;

/* Refreshes an attached view's backing-size snapshot after AppKit changes. */
- (void)update;

/* Copies the AppKit lifecycle state into the framework's C-only CVK record. */
- (BOOL)getCVKSurfaceSnapshot:(CVKSurfaceSnapshot *)outSnapshot;

/*
 * Retains and configures an application-supplied CAMetalLayer. This bridge
 * never replaces NSView.layer itself; the application owns layer-tree policy.
 */
- (BOOL)attachMetalLayer:(CAMetalLayer *)layer;

/* Detaches the AppKit drawable state without destroying any future CVK surface. */
- (void)clearDrawable;

@end

NS_ASSUME_NONNULL_END

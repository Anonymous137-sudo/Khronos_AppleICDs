/*
 * Copyright 2026 Khronos_AppleICDs contributors
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <mach/kern_return.h>

struct pipe_screen;
struct agx_macos_device_session;

enum AppleOpenGLAsahiBackendState {
   APPLE_OPENGL_ASAHI_BACKEND_UNINITIALIZED = 0,
   APPLE_OPENGL_ASAHI_BACKEND_NO_DEVICE,
   APPLE_OPENGL_ASAHI_BACKEND_UNSUPPORTED_DEVICE,
   APPLE_OPENGL_ASAHI_BACKEND_WINSYS_INCOMPLETE,
   APPLE_OPENGL_ASAHI_BACKEND_READY,
};

enum AppleOpenGLAsahiContextBlocker {
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DEVICE_SESSION = 1u << 0,
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_SCREEN_FACTORY = 1u << 1,
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DIRECT_SUBMISSION = 1u << 2,
   APPLE_OPENGL_ASAHI_CONTEXT_BLOCKER_DRAWABLE_PRESENTATION = 1u << 3,
};

enum AppleOpenGLAsahiBackendState AppleOpenGLAsahiInitialize(void);
const char *AppleOpenGLAsahiBackendStateName(
   enum AppleOpenGLAsahiBackendState state);
const struct agx_macos_device_session *AppleOpenGLAsahiGetDeviceSession(void);
/* A zero mask permits screen creation. AO46 never lowers a request to a
 * fallback backend when any native prerequisite is still missing. */
uint32_t AppleOpenGLAsahiContextBlockers(void);
const char *AppleOpenGLAsahiContextBlockerName(uint32_t blocker);
/* Checks only whether AO46's core-profile request is in its supported API
 * range. It does not imply native winsys readiness or expose a GL version. */
bool AppleOpenGLAsahiCoreProfileRequestIsInRange(unsigned major,
                                                 unsigned minor);
/* Creates the native AGX screen ownership root for WIP diagnostics. It does
 * not create a Mesa pipe_screen or expose a GL context. */
bool AppleOpenGLAsahiBootstrapNativeScreen(void);
bool AppleOpenGLAsahiNativeScreenBootstrapIsReady(void);
kern_return_t AppleOpenGLAsahiDestroyNativeScreenBootstrap(void);
bool AppleOpenGLAsahiCanCreateCoreProfile(unsigned major, unsigned minor);
bool AppleOpenGLAsahiCanPresentWindow(void);
struct pipe_screen *AppleOpenGLAsahiCreateScreen(void);

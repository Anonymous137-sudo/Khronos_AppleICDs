#ifndef APPLE_NS_OPENGL_COMPAT_H
#define APPLE_NS_OPENGL_COMPAT_H

#include <stdint.h>

#include <OpenGL/CGLTypes.h>
#include "AppleOpenGL46Runtime.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#define AO46_NULLABLE nullable
#define AO46_NULLABLE_C _Nullable
#define AO46_NONNULL nonnull
#define AO46_ASSUME_NONNULL_BEGIN NS_ASSUME_NONNULL_BEGIN
#define AO46_ASSUME_NONNULL_END NS_ASSUME_NONNULL_END
#else
#define AO46_NULLABLE
#define AO46_NULLABLE_C
#define AO46_NONNULL
#define AO46_ASSUME_NONNULL_BEGIN
#define AO46_ASSUME_NONNULL_END
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    AO46NSOpenGLGOFormatCacheSize = 501,
    AO46NSOpenGLGOClearFormatCache = 502,
    AO46NSOpenGLGORetainRenderers = 503,
    AO46NSOpenGLGOResetLibrary = 504,
    AO46NSOpenGLGOUseBuildCache = 506
} AO46NSOpenGLGlobalOption;

typedef uint32_t AO46NSOpenGLPixelFormatAttribute;

enum {
    AO46NSOpenGLPFAAllRenderers = 1,
    AO46NSOpenGLPFATripleBuffer = 3,
    AO46NSOpenGLPFADoubleBuffer = 5,
    AO46NSOpenGLPFAStereo = 6,
    AO46NSOpenGLPFAAuxBuffers = 7,
    AO46NSOpenGLPFAColorSize = 8,
    AO46NSOpenGLPFAAlphaSize = 11,
    AO46NSOpenGLPFADepthSize = 12,
    AO46NSOpenGLPFAStencilSize = 13,
    AO46NSOpenGLPFAAccumSize = 14,
    AO46NSOpenGLPFAMinimumPolicy = 51,
    AO46NSOpenGLPFAMaximumPolicy = 52,
    AO46NSOpenGLPFAOffScreen = 53,
    AO46NSOpenGLPFAFullScreen = 54,
    AO46NSOpenGLPFASampleBuffers = 55,
    AO46NSOpenGLPFASamples = 56,
    AO46NSOpenGLPFAAuxDepthStencil = 57,
    AO46NSOpenGLPFAColorFloat = 58,
    AO46NSOpenGLPFAMultisample = 59,
    AO46NSOpenGLPFASupersample = 60,
    AO46NSOpenGLPFASampleAlpha = 61,
    AO46NSOpenGLPFARendererID = 70,
    AO46NSOpenGLPFASingleRenderer = 71,
    AO46NSOpenGLPFANoRecovery = 72,
    AO46NSOpenGLPFAAccelerated = 73,
    AO46NSOpenGLPFAClosestPolicy = 74,
    AO46NSOpenGLPFARobust = 75,
    AO46NSOpenGLPFABackingStore = 76,
    AO46NSOpenGLPFAMPSafe = 78,
    AO46NSOpenGLPFAWindow = 80,
    AO46NSOpenGLPFAMultiScreen = 81,
    AO46NSOpenGLPFACompliant = 83,
    AO46NSOpenGLPFAScreenMask = 84,
    AO46NSOpenGLPFAPixelBuffer = 90,
    AO46NSOpenGLPFARemotePixelBuffer = 91,
    AO46NSOpenGLPFAAllowOfflineRenderers = 96,
    AO46NSOpenGLPFAAcceleratedCompute = 97,
    AO46NSOpenGLPFAOpenGLProfile = 99,
    AO46NSOpenGLPFAVirtualScreenCount = 128
};

enum {
    AO46NSOpenGLProfileVersionLegacy = 0x1000,
    AO46NSOpenGLProfileVersion3_2Core = 0x3200,
    AO46NSOpenGLProfileVersion4_1Core = 0x4100,
    AO46NSOpenGLProfileVersion4_6Core = 0x4600
};

typedef GLint AO46NSOpenGLContextParameter;

enum {
    AO46NSOpenGLContextParameterSwapRectangle = 200,
    AO46NSOpenGLContextParameterSwapRectangleEnable = 201,
    AO46NSOpenGLContextParameterRasterizationEnable = 221,
    AO46NSOpenGLContextParameterSwapInterval = 222,
    AO46NSOpenGLContextParameterSurfaceOrder = 235,
    AO46NSOpenGLContextParameterSurfaceOpacity = 236,
    AO46NSOpenGLContextParameterStateValidation = 301,
    AO46NSOpenGLContextParameterSurfaceBackingSize = 304,
    AO46NSOpenGLContextParameterSurfaceSurfaceVolatile = 306,
    AO46NSOpenGLContextParameterReclaimResources = 308,
    AO46NSOpenGLContextParameterCurrentRendererID = 309,
    AO46NSOpenGLContextParameterGPUVertexProcessing = 310,
    AO46NSOpenGLContextParameterGPUFragmentProcessing = 311,
    AO46NSOpenGLContextParameterHasDrawable = 314,
    AO46NSOpenGLContextParameterMPSwapsInFlight = 315
};

void AO46NSOpenGLSetOption(AO46NSOpenGLGlobalOption pname, GLint param);
void AO46NSOpenGLGetOption(AO46NSOpenGLGlobalOption pname, GLint * AO46_NULLABLE_C param);
void AO46NSOpenGLGetVersion(GLint * AO46_NULLABLE_C major, GLint * AO46_NULLABLE_C minor);

void NSOpenGLSetOption(AO46NSOpenGLGlobalOption pname, GLint param);
void NSOpenGLGetOption(AO46NSOpenGLGlobalOption pname, GLint * AO46_NULLABLE_C param);
void NSOpenGLGetVersion(GLint * AO46_NULLABLE_C major, GLint * AO46_NULLABLE_C minor);

#ifdef __OBJC__
@class AO46NSOpenGLPixelBuffer;
@class NSView;

AO46_ASSUME_NONNULL_BEGIN

@interface AO46NSOpenGLPixelFormat : NSObject <NSSecureCoding>

- (AO46_NULLABLE instancetype)initWithCGLPixelFormatObj:(CGLPixelFormatObj AO46_NULLABLE_C)format;
- (AO46_NULLABLE instancetype)initWithAttributes:(const AO46NSOpenGLPixelFormatAttribute * AO46_NULLABLE_C)attribs;
- (AO46_NULLABLE instancetype)initWithData:(NSData *)attribs;
- (NSData *)attributes;
- (void)setAttributes:(NSData *)attribs;
- (void)getValues:(GLint * AO46_NULLABLE_C)vals
     forAttribute:(AO46NSOpenGLPixelFormatAttribute)attrib
 forVirtualScreen:(GLint)screen;
@property (readonly) GLint numberOfVirtualScreens;
@property (AO46_NULLABLE, readonly) CGLPixelFormatObj CGLPixelFormatObj;

@end

@interface AO46NSOpenGLPixelBuffer : NSObject

- (nullable instancetype)initWithTextureTarget:(GLenum)target
                         textureInternalFormat:(GLenum)format
                          textureMaxMipMapLevel:(GLint)maxLevel
                                     pixelsWide:(GLsizei)pixelsWide
                                     pixelsHigh:(GLsizei)pixelsHigh;
- (AO46_NULLABLE instancetype)initWithCGLPBufferObj:(CGLPBufferObj AO46_NULLABLE_C)pbuffer;
@property (AO46_NULLABLE, readonly) CGLPBufferObj CGLPBufferObj;
@property (readonly) GLsizei pixelsWide;
@property (readonly) GLsizei pixelsHigh;
@property (readonly) GLenum textureTarget;
@property (readonly) GLenum textureInternalFormat;
@property (readonly) GLint textureMaxMipMapLevel;

@end

@interface AO46NSOpenGLContext : NSObject <NSLocking>

- (AO46_NULLABLE instancetype)initWithFormat:(AO46NSOpenGLPixelFormat * AO46_NULLABLE_C)format
                                shareContext:(AO46NSOpenGLContext * AO46_NULLABLE_C)share;
- (AO46_NULLABLE instancetype)initWithCGLContextObj:(CGLContextObj AO46_NULLABLE_C)context;
@property (AO46_NULLABLE, readonly, strong) AO46NSOpenGLPixelFormat *pixelFormat;
@property (AO46_NULLABLE, weak) NSView *view;
- (void)setView:(NSView * AO46_NULLABLE_C)view;
- (void)setFullScreen;
- (void)setOffScreen:(void * AO46_NULLABLE_C)baseaddr width:(GLsizei)width height:(GLsizei)height rowbytes:(GLint)rowbytes;
- (void)clearDrawable;
- (void)update;
- (void)flushBuffer;
- (void)makeCurrentContext;
+ (void)clearCurrentContext;
@property (class, readonly, AO46_NULLABLE, strong) AO46NSOpenGLContext *currentContext;
- (void)copyAttributesFromContext:(AO46NSOpenGLContext * AO46_NULLABLE_C)context withMask:(GLbitfield)mask;
- (void)setValues:(const GLint * AO46_NULLABLE_C)vals forParameter:(AO46NSOpenGLContextParameter)param;
- (void)getValues:(GLint * AO46_NULLABLE_C)vals forParameter:(AO46NSOpenGLContextParameter)param;
@property GLint currentVirtualScreen;
@property (AO46_NULLABLE, readonly) CGLContextObj CGLContextObj;
- (void)setPixelBuffer:(AO46NSOpenGLPixelBuffer * AO46_NULLABLE_C)pixelBuffer
           cubeMapFace:(GLenum)face
           mipMapLevel:(GLint)level
  currentVirtualScreen:(GLint)screen;
- (AO46_NULLABLE AO46NSOpenGLPixelBuffer *)pixelBuffer;
- (GLenum)pixelBufferCubeMapFace;
- (GLint)pixelBufferMipMapLevel;
- (void)createTexture:(GLenum)target fromView:(NSView * AO46_NULLABLE_C)view internalFormat:(GLenum)format;
- (void)setTextureImageToPixelBuffer:(AO46NSOpenGLPixelBuffer * AO46_NULLABLE_C)pixelBuffer colorBuffer:(GLenum)source;

@end

AO46_ASSUME_NONNULL_END
#endif

#ifdef __cplusplus
}
#endif

#endif

#import "AppleNSOpenGLCompat.h"
#import "AppleOpenGL46Client.h"
#import <AppKit/NSView.h>

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kAO46NSOpenGLCurrentContextKey = @"local.opengl46.driver.current-context";
static NSString *const kAO46NSOpenGLPixelFormatAttributesKey = @"attributes";

static bool ao46_ns_attrib_has_value(AO46NSOpenGLPixelFormatAttribute attrib)
{
    switch (attrib) {
        case AO46NSOpenGLPFAColorSize:
        case AO46NSOpenGLPFAAlphaSize:
        case AO46NSOpenGLPFADepthSize:
        case AO46NSOpenGLPFAStencilSize:
        case AO46NSOpenGLPFASampleBuffers:
        case AO46NSOpenGLPFASamples:
        case AO46NSOpenGLPFAAuxBuffers:
        case AO46NSOpenGLPFAAccumSize:
        case AO46NSOpenGLPFARendererID:
        case AO46NSOpenGLPFAScreenMask:
        case AO46NSOpenGLPFAOpenGLProfile:
        case AO46NSOpenGLPFAVirtualScreenCount:
            return true;
        default:
            return false;
    }
}

static NSData *ao46_ns_default_attribute_data(void)
{
    const AO46NSOpenGLPixelFormatAttribute default_attribs[] = { 0 };

    return [NSData dataWithBytes:default_attribs length:sizeof(default_attribs)];
}

static NSData *ao46_ns_copy_attribute_data(const AO46NSOpenGLPixelFormatAttribute *attribs)
{
    const AO46NSOpenGLPixelFormatAttribute default_attribs[] = { 0 };
    const AO46NSOpenGLPixelFormatAttribute *source = attribs ? attribs : default_attribs;
    size_t word_count = 0;
    size_t index = 0;

    for (;;) {
        AO46NSOpenGLPixelFormatAttribute attrib = source[index++];
        word_count++;
        if (attrib == 0) {
            break;
        }
        if (ao46_ns_attrib_has_value(attrib)) {
            index++;
            word_count++;
        }
    }

    return [NSData dataWithBytes:source length:word_count * sizeof(*source)];
}

static NSData *ao46_ns_normalize_attribute_data(NSData *attrib_data)
{
    const AO46NSOpenGLPixelFormatAttribute *words;
    size_t word_count;
    size_t index = 0;

    if (!attrib_data || attrib_data.length == 0) {
        return ao46_ns_default_attribute_data();
    }

    if ((attrib_data.length % sizeof(AO46NSOpenGLPixelFormatAttribute)) != 0) {
        return nil;
    }

    words = attrib_data.bytes;
    word_count = attrib_data.length / sizeof(*words);

    while (index < word_count) {
        AO46NSOpenGLPixelFormatAttribute attrib = words[index++];
        if (attrib == 0) {
            return index == word_count ? [attrib_data copy] : nil;
        }
        if (ao46_ns_attrib_has_value(attrib)) {
            if (index >= word_count) {
                return nil;
            }
            index++;
        }
    }

    NSMutableData *normalized = [attrib_data mutableCopy];
    AO46NSOpenGLPixelFormatAttribute terminator = 0;

    [normalized appendBytes:&terminator length:sizeof(terminator)];
    return [normalized copy];
}

static CGLPixelFormatAttribute *ao46_ns_copy_pixel_format_attributes_from_words(const AO46NSOpenGLPixelFormatAttribute *words,
                                                                                size_t word_count)
{
    CGLPixelFormatAttribute *translated = (CGLPixelFormatAttribute *)calloc(word_count, sizeof(*translated));
    if (!translated) {
        return NULL;
    }

    for (size_t index = 0; index < word_count; ++index) {
        translated[index] = (CGLPixelFormatAttribute)words[index];
    }

    return translated;
}

static CGLPixelFormatAttribute *ao46_ns_copy_pixel_format_attributes_from_data(NSData *attrib_data)
{
    NSData *normalized = ao46_ns_normalize_attribute_data(attrib_data);
    const AO46NSOpenGLPixelFormatAttribute *words;

    if (!normalized) {
        return NULL;
    }

    words = normalized.bytes;
    return ao46_ns_copy_pixel_format_attributes_from_words(words,
                                                           normalized.length / sizeof(*words));
}

static void ao46_ns_zero_values(GLint *vals, size_t count)
{
    if (!vals) {
        return;
    }

    memset(vals, 0, count * sizeof(*vals));
}

static void *ao46_ns_resolve_view_drawable(NSView *view)
{
    NSWindow *window;

    if (!view) {
        return NULL;
    }

    window = [view window];
    return (__bridge void *)(window ? (id)window : (id)view);
}

static void ao46_ns_attach_view_drawable_if_needed(AO46ContextRef context,
                                                    NSView *view)
{
    void *drawable = ao46_ns_resolve_view_drawable(view);

    if (context && drawable &&
        AO46ClientGetWindowHandleForContext(context) != drawable) {
        (void)AO46ClientAttachWindowToContext(context, drawable);
    }
}

@interface AO46NSOpenGLPixelFormat () {
    AO46PixelFormatRef _pixelFormat;
    NSData *_attributeData;
}

- (BOOL)ao46_replacePixelFormatWithAttributeData:(NSData *)attribData;

@end

static void ao46_ns_append_attribute(NSMutableData *data, AO46NSOpenGLPixelFormatAttribute attrib)
{
    [data appendBytes:&attrib length:sizeof(attrib)];
}

static void ao46_ns_append_attribute_with_value(NSMutableData *data,
                                                AO46NSOpenGLPixelFormatAttribute attrib,
                                                GLint value)
{
    AO46NSOpenGLPixelFormatAttribute stored_value = (AO46NSOpenGLPixelFormatAttribute)value;

    ao46_ns_append_attribute(data, attrib);
    [data appendBytes:&stored_value length:sizeof(stored_value)];
}

static void ao46_ns_append_flag_attribute_if_enabled(NSMutableData *data,
                                                     AO46PixelFormatRef format,
                                                     AO46NSOpenGLPixelFormatAttribute attrib)
{
    GLint value = 0;

    if (AO46ClientDescribePixelFormat(format, 0, (CGLPixelFormatAttribute)attrib, &value) == kCGLNoError &&
        value != 0) {
        ao46_ns_append_attribute(data, attrib);
    }
}

static void ao46_ns_append_value_attribute_if_present(NSMutableData *data,
                                                      AO46PixelFormatRef format,
                                                      AO46NSOpenGLPixelFormatAttribute attrib)
{
    GLint value = 0;

    if (AO46ClientDescribePixelFormat(format, 0, (CGLPixelFormatAttribute)attrib, &value) == kCGLNoError &&
        value != 0) {
        ao46_ns_append_attribute_with_value(data, attrib, value);
    }
}

static NSData *ao46_ns_synthesize_attribute_data_for_pixel_format(AO46PixelFormatRef format)
{
    const AO46NSOpenGLPixelFormatAttribute flag_attributes[] = {
        AO46NSOpenGLPFAAllRenderers,
        AO46NSOpenGLPFATripleBuffer,
        AO46NSOpenGLPFADoubleBuffer,
        AO46NSOpenGLPFAStereo,
        AO46NSOpenGLPFAMinimumPolicy,
        AO46NSOpenGLPFAMaximumPolicy,
        AO46NSOpenGLPFAOffScreen,
        AO46NSOpenGLPFAFullScreen,
        AO46NSOpenGLPFAAuxDepthStencil,
        AO46NSOpenGLPFAColorFloat,
        AO46NSOpenGLPFAMultisample,
        AO46NSOpenGLPFASupersample,
        AO46NSOpenGLPFASampleAlpha,
        AO46NSOpenGLPFASingleRenderer,
        AO46NSOpenGLPFANoRecovery,
        AO46NSOpenGLPFAAccelerated,
        AO46NSOpenGLPFAClosestPolicy,
        AO46NSOpenGLPFABackingStore,
        AO46NSOpenGLPFAMPSafe,
        AO46NSOpenGLPFAWindow,
        AO46NSOpenGLPFAMultiScreen,
        AO46NSOpenGLPFACompliant,
        AO46NSOpenGLPFAPixelBuffer,
        AO46NSOpenGLPFARemotePixelBuffer,
        AO46NSOpenGLPFAAllowOfflineRenderers,
        AO46NSOpenGLPFAAcceleratedCompute,
        AO46NSOpenGLPFARobust
    };
    const AO46NSOpenGLPixelFormatAttribute value_attributes[] = {
        AO46NSOpenGLPFAAuxBuffers,
        AO46NSOpenGLPFAColorSize,
        AO46NSOpenGLPFAAlphaSize,
        AO46NSOpenGLPFADepthSize,
        AO46NSOpenGLPFAStencilSize,
        AO46NSOpenGLPFAAccumSize,
        AO46NSOpenGLPFASampleBuffers,
        AO46NSOpenGLPFASamples,
        AO46NSOpenGLPFARendererID,
        AO46NSOpenGLPFAScreenMask,
        AO46NSOpenGLPFAOpenGLProfile,
        AO46NSOpenGLPFAVirtualScreenCount
    };
    NSMutableData *data = [NSMutableData data];
    AO46NSOpenGLPixelFormatAttribute terminator = 0;

    if (!format) {
        return ao46_ns_default_attribute_data();
    }

    for (size_t index = 0; index < sizeof(flag_attributes) / sizeof(flag_attributes[0]); ++index) {
        ao46_ns_append_flag_attribute_if_enabled(data, format, flag_attributes[index]);
    }

    for (size_t index = 0; index < sizeof(value_attributes) / sizeof(value_attributes[0]); ++index) {
        ao46_ns_append_value_attribute_if_present(data, format, value_attributes[index]);
    }

    [data appendBytes:&terminator length:sizeof(terminator)];
    return [data copy];
}

@implementation AO46NSOpenGLPixelFormat

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (instancetype)init
{
    return [self initWithAttributes:NULL];
}

- (instancetype)initWithCGLPixelFormatObj:(CGLPixelFormatObj)format
{
    self = [super init];
    if (!self) {
        return nil;
    }

    if (!format) {
        return nil;
    }

    _pixelFormat = AO46ClientRetainPixelFormat((AO46PixelFormatRef)format);
    if (!_pixelFormat) {
        return nil;
    }

    _attributeData = ao46_ns_synthesize_attribute_data_for_pixel_format(_pixelFormat);
    return self;
}

- (instancetype)initWithAttributes:(const AO46NSOpenGLPixelFormatAttribute *)attribs
{
    NSData *attribute_data = ao46_ns_copy_attribute_data(attribs);
    CGLPixelFormatAttribute *translated = ao46_ns_copy_pixel_format_attributes_from_data(attribute_data);
    AO46PixelFormatRef pixel_format = NULL;
    GLint npix = 0;
    AO46NSOpenGLPixelFormat *object = nil;

    if (!translated) {
        return nil;
    }

    if (AO46ClientChoosePixelFormat(translated, &pixel_format, &npix) != kCGLNoError ||
        !pixel_format ||
        npix <= 0) {
        free(translated);
        return nil;
    }

    free(translated);
    object = [self initWithCGLPixelFormatObj:(CGLPixelFormatObj)pixel_format];
    AO46ClientDestroyPixelFormat(pixel_format);
    if (object && attribute_data) {
        object->_attributeData = attribute_data;
    }
    return object;
}

- (instancetype)initWithData:(NSData *)attribs
{
    self = [super init];
    if (!self) {
        return nil;
    }

    if (![self ao46_replacePixelFormatWithAttributeData:attribs]) {
        return nil;
    }

    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *attribute_data = nil;

    if ([coder allowsKeyedCoding]) {
        if ([coder respondsToSelector:@selector(decodeObjectOfClass:forKey:)]) {
            attribute_data = [coder decodeObjectOfClass:[NSData class]
                                                 forKey:kAO46NSOpenGLPixelFormatAttributesKey];
        } else {
            attribute_data = [coder decodeObjectForKey:kAO46NSOpenGLPixelFormatAttributesKey];
        }
    } else {
        attribute_data = [coder decodeObject];
    }

    return [self initWithData:attribute_data];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSData *attribute_data = [self attributes];

    if ([coder allowsKeyedCoding]) {
        [coder encodeObject:attribute_data forKey:kAO46NSOpenGLPixelFormatAttributesKey];
    } else {
        [coder encodeObject:attribute_data];
    }
}

- (void)dealloc
{
    AO46ClientDestroyPixelFormat(_pixelFormat);
}

- (BOOL)ao46_replacePixelFormatWithAttributeData:(NSData *)attribData
{
    NSData *normalized_data = ao46_ns_normalize_attribute_data(attribData);
    const AO46NSOpenGLPixelFormatAttribute *words;
    size_t word_count;
    CGLPixelFormatAttribute *translated;
    AO46PixelFormatRef pixel_format = NULL;
    GLint npix = 0;

    if (!normalized_data) {
        return NO;
    }

    words = normalized_data.bytes;
    word_count = normalized_data.length / sizeof(*words);
    translated = ao46_ns_copy_pixel_format_attributes_from_words(words, word_count);
    if (!translated) {
        return NO;
    }

    if (AO46ClientChoosePixelFormat(translated, &pixel_format, &npix) != kCGLNoError ||
        !pixel_format ||
        npix <= 0) {
        free(translated);
        if (pixel_format) {
            AO46ClientDestroyPixelFormat(pixel_format);
        }
        return NO;
    }

    free(translated);
    AO46ClientDestroyPixelFormat(_pixelFormat);
    _pixelFormat = pixel_format;
    _attributeData = normalized_data;
    return YES;
}

- (NSData *)attributes
{
    if (!_attributeData) {
        _attributeData = ao46_ns_synthesize_attribute_data_for_pixel_format(_pixelFormat);
    }

    return _attributeData ? _attributeData : ao46_ns_default_attribute_data();
}

- (void)setAttributes:(NSData *)attribs
{
    (void)[self ao46_replacePixelFormatWithAttributeData:attribs];
}

- (void)getValues:(GLint *)vals
     forAttribute:(AO46NSOpenGLPixelFormatAttribute)attrib
 forVirtualScreen:(GLint)screen
{
    if (AO46ClientDescribePixelFormat(_pixelFormat,
                                      screen,
                                      (CGLPixelFormatAttribute)attrib,
                                      vals) != kCGLNoError) {
        ao46_ns_zero_values(vals, 1);
    }
}

- (GLint)numberOfVirtualScreens
{
    GLint value = 0;

    [self getValues:&value
       forAttribute:AO46NSOpenGLPFAVirtualScreenCount
   forVirtualScreen:0];
    return value;
}

- (CGLPixelFormatObj)CGLPixelFormatObj
{
    return (CGLPixelFormatObj)_pixelFormat;
}

@end

@interface AO46NSOpenGLPixelBuffer () {
    AO46PBufferRef _pbuffer;
}
@end

@implementation AO46NSOpenGLPixelBuffer

- (instancetype)initWithTextureTarget:(GLenum)target
                textureInternalFormat:(GLenum)format
                 textureMaxMipMapLevel:(GLint)maxLevel
                            pixelsWide:(GLsizei)pixelsWide
                            pixelsHigh:(GLsizei)pixelsHigh
{
    AO46PBufferRef pbuffer = NULL;

    self = [super init];
    if (!self) {
        return nil;
    }

    if (AO46ClientCreatePBuffer(pixelsWide,
                                pixelsHigh,
                                target,
                                format,
                                maxLevel,
                                &pbuffer) != kCGLNoError ||
        !pbuffer) {
        return nil;
    }

    _pbuffer = pbuffer;
    return self;
}

- (instancetype)initWithCGLPBufferObj:(CGLPBufferObj)pbuffer
{
    self = [super init];
    if (!self) {
        return nil;
    }

    if (!pbuffer) {
        return nil;
    }

    _pbuffer = AO46ClientRetainPBuffer((AO46PBufferRef)pbuffer);
    if (!_pbuffer) {
        return nil;
    }

    return self;
}

- (void)dealloc
{
    AO46ClientDestroyPBuffer(_pbuffer);
}

- (void)describeWidth:(GLsizei *)width
               height:(GLsizei *)height
               target:(GLenum *)target
       internalFormat:(GLenum *)internalFormat
               mipmap:(GLint *)mipmap
{
    AO46ClientDescribePBuffer(_pbuffer, width, height, target, internalFormat, mipmap);
}

- (CGLPBufferObj)CGLPBufferObj
{
    return (CGLPBufferObj)_pbuffer;
}

- (GLsizei)pixelsWide
{
    GLsizei width = 0;

    [self describeWidth:&width height:NULL target:NULL internalFormat:NULL mipmap:NULL];
    return width;
}

- (GLsizei)pixelsHigh
{
    GLsizei height = 0;

    [self describeWidth:NULL height:&height target:NULL internalFormat:NULL mipmap:NULL];
    return height;
}

- (GLenum)textureTarget
{
    GLenum target = 0;

    [self describeWidth:NULL height:NULL target:&target internalFormat:NULL mipmap:NULL];
    return target;
}

- (GLenum)textureInternalFormat
{
    GLenum internal_format = 0;

    [self describeWidth:NULL height:NULL target:NULL internalFormat:&internal_format mipmap:NULL];
    return internal_format;
}

- (GLint)textureMaxMipMapLevel
{
    GLint mipmap = 0;

    [self describeWidth:NULL height:NULL target:NULL internalFormat:NULL mipmap:&mipmap];
    return mipmap;
}

@end

@interface AO46NSOpenGLContext () {
    AO46ContextRef _context;
    AO46NSOpenGLPixelFormat *_pixelFormat;
    AO46NSOpenGLPixelBuffer *_pixelBuffer;
    __weak NSView *_view;
    GLenum _pixelBufferFace;
    GLint _pixelBufferMipMapLevel;
}
@end

@implementation AO46NSOpenGLContext

- (instancetype)initWithFormat:(AO46NSOpenGLPixelFormat *)format
                  shareContext:(AO46NSOpenGLContext *)share
{
    AO46ContextRef context = NULL;

    self = [super init];
    if (!self) {
        return nil;
    }

    if (!format) {
        return nil;
    }

    if (AO46ClientCreateContext((AO46PixelFormatRef)format.CGLPixelFormatObj,
                                share ? (AO46ContextRef)share.CGLContextObj : NULL,
                                &context) != kCGLNoError ||
        !context) {
        return nil;
    }

    _context = context;
    _pixelFormat = format;
    return self;
}

- (instancetype)initWithCGLContextObj:(CGLContextObj)context
{
    AO46PixelFormatRef pixel_format = NULL;

    self = [super init];
    if (!self) {
        return nil;
    }

    if (!context) {
        return nil;
    }

    _context = AO46ClientRetainContext((AO46ContextRef)context);
    if (!_context) {
        return nil;
    }

    pixel_format = AO46ClientGetPixelFormatForContext(_context);
    if (pixel_format) {
        _pixelFormat = [[AO46NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:(CGLPixelFormatObj)pixel_format];
    }

    return self;
}

- (void)dealloc
{
    NSMutableDictionary *thread_dictionary = [[NSThread currentThread] threadDictionary];
    id current = thread_dictionary[kAO46NSOpenGLCurrentContextKey];

    if (current == self) {
        [thread_dictionary removeObjectForKey:kAO46NSOpenGLCurrentContextKey];
    }

    AO46ClientDestroyContext(_context);
}

- (AO46NSOpenGLPixelFormat *)pixelFormat
{
    if (!_pixelFormat && _context) {
        AO46PixelFormatRef pixel_format = AO46ClientGetPixelFormatForContext(_context);
        if (pixel_format) {
            _pixelFormat = [[AO46NSOpenGLPixelFormat alloc] initWithCGLPixelFormatObj:(CGLPixelFormatObj)pixel_format];
        }
    }

    return _pixelFormat;
}

- (NSView *)view
{
    return _view;
}

- (void)setView:(NSView *)view
{
    _view = view;
    _pixelBuffer = nil;
    _pixelBufferFace = 0;
    _pixelBufferMipMapLevel = 0;

    if (!view) {
        (void)AO46ClientClearDrawable(_context);
        return;
    }

    ao46_ns_attach_view_drawable_if_needed(_context, view);
}

- (void)setFullScreen
{
    if (AO46ClientSetFullScreen(_context) == kCGLNoError) {
        _view = nil;
        _pixelBuffer = nil;
        _pixelBufferFace = 0;
        _pixelBufferMipMapLevel = 0;
    }
}

- (void)setOffScreen:(void *)baseaddr width:(GLsizei)width height:(GLsizei)height rowbytes:(GLint)rowbytes
{
    if (AO46ClientSetOffScreen(_context, width, height, rowbytes, baseaddr) == kCGLNoError) {
        _view = nil;
        _pixelBuffer = nil;
        _pixelBufferFace = 0;
        _pixelBufferMipMapLevel = 0;
    }
}

- (void)clearDrawable
{
    if (AO46ClientClearDrawable(_context) == kCGLNoError) {
        _view = nil;
        _pixelBuffer = nil;
        _pixelBufferFace = 0;
        _pixelBufferMipMapLevel = 0;
    }
}

- (void)update
{
    if (_view) {
        ao46_ns_attach_view_drawable_if_needed(_context, _view);
    }
    (void)AO46ClientUpdateContext(_context);
}

- (void)flushBuffer
{
    if (_view) {
        ao46_ns_attach_view_drawable_if_needed(_context, _view);
    }
    (void)AO46ClientFlushDrawable(_context);
}

- (void)makeCurrentContext
{
    if (AO46ClientSetCurrentContext(_context) == kCGLNoError) {
        [[[NSThread currentThread] threadDictionary] setObject:self
                                                        forKey:kAO46NSOpenGLCurrentContextKey];
    }
}

+ (void)clearCurrentContext
{
    (void)AO46ClientSetCurrentContext(NULL);
    [[[NSThread currentThread] threadDictionary] removeObjectForKey:kAO46NSOpenGLCurrentContextKey];
}

+ (AO46NSOpenGLContext *)currentContext
{
    AO46ContextRef current_context = AO46ClientGetCurrentContext();
    NSMutableDictionary *thread_dictionary = [[NSThread currentThread] threadDictionary];
    AO46NSOpenGLContext *wrapper = thread_dictionary[kAO46NSOpenGLCurrentContextKey];

    if (!current_context) {
        [thread_dictionary removeObjectForKey:kAO46NSOpenGLCurrentContextKey];
        return nil;
    }

    if (wrapper && wrapper.CGLContextObj == (CGLContextObj)current_context) {
        return wrapper;
    }

    wrapper = [[self alloc] initWithCGLContextObj:(CGLContextObj)current_context];
    if (wrapper) {
        thread_dictionary[kAO46NSOpenGLCurrentContextKey] = wrapper;
    }
    return wrapper;
}

- (void)copyAttributesFromContext:(AO46NSOpenGLContext *)context withMask:(GLbitfield)mask
{
    if (!context) {
        return;
    }

    (void)AO46ClientCopyContext((AO46ContextRef)context.CGLContextObj, _context, mask);
}

- (void)setValues:(const GLint *)vals forParameter:(AO46NSOpenGLContextParameter)param
{
    const GLint *params = param == AO46NSOpenGLContextParameterReclaimResources ? NULL : vals;
    (void)AO46ClientSetContextParameter(_context, (CGLContextParameter)param, params);
}

- (void)getValues:(GLint *)vals forParameter:(AO46NSOpenGLContextParameter)param
{
    size_t value_count = param == AO46NSOpenGLContextParameterSwapRectangle ? 4 :
                         param == AO46NSOpenGLContextParameterSurfaceBackingSize ? 2 : 1;

    if (AO46ClientGetContextParameter(_context, (CGLContextParameter)param, vals) != kCGLNoError) {
        ao46_ns_zero_values(vals, value_count);
    }
}

- (GLint)currentVirtualScreen
{
    GLint screen = 0;

    if (AO46ClientGetVirtualScreen(_context, &screen) != kCGLNoError) {
        return 0;
    }

    return screen;
}

- (void)setCurrentVirtualScreen:(GLint)currentVirtualScreen
{
    (void)AO46ClientSetVirtualScreen(_context, currentVirtualScreen);
}

- (CGLContextObj)CGLContextObj
{
    return (CGLContextObj)_context;
}

- (void)setPixelBuffer:(AO46NSOpenGLPixelBuffer *)pixelBuffer
           cubeMapFace:(GLenum)face
           mipMapLevel:(GLint)level
  currentVirtualScreen:(GLint)screen
{
    if (!pixelBuffer) {
        [self clearDrawable];
        return;
    }

    if (AO46ClientSetPBuffer(_context,
                             (AO46PBufferRef)pixelBuffer.CGLPBufferObj,
                             face,
                             level,
                             screen) == kCGLNoError) {
        _view = nil;
        _pixelBuffer = pixelBuffer;
        _pixelBufferFace = face;
        _pixelBufferMipMapLevel = level;
    }
}

- (AO46NSOpenGLPixelBuffer *)pixelBuffer
{
    AO46PBufferRef pbuffer = NULL;
    GLint screen = 0;

    if (_pixelBuffer) {
        return _pixelBuffer;
    }

    if (AO46ClientGetPBuffer(_context, &pbuffer, &_pixelBufferFace, &_pixelBufferMipMapLevel, &screen) != kCGLNoError ||
        !pbuffer) {
        return nil;
    }

    _pixelBuffer = [[AO46NSOpenGLPixelBuffer alloc] initWithCGLPBufferObj:(CGLPBufferObj)pbuffer];
    return _pixelBuffer;
}

- (GLenum)pixelBufferCubeMapFace
{
    (void)[self pixelBuffer];
    return _pixelBufferFace;
}

- (GLint)pixelBufferMipMapLevel
{
    (void)[self pixelBuffer];
    return _pixelBufferMipMapLevel;
}

- (void)createTexture:(GLenum)target fromView:(NSView *)view internalFormat:(GLenum)format
{
    (void)target;
    (void)format;

    [self setView:view];
}

- (void)setTextureImageToPixelBuffer:(AO46NSOpenGLPixelBuffer *)pixelBuffer colorBuffer:(GLenum)source
{
    if (!pixelBuffer) {
        return;
    }

    (void)AO46ClientTexImagePBuffer(_context, (AO46PBufferRef)pixelBuffer.CGLPBufferObj, source);
}

- (void)lock
{
    (void)AO46ClientLockContext(_context);
}

- (void)unlock
{
    (void)AO46ClientUnlockContext(_context);
}

@end

static void ao46_ns_set_global_option(AO46NSOpenGLGlobalOption pname, GLint param)
{
    (void)AO46ClientSetGlobalOption((CGLGlobalOption)pname, &param);
}

static void ao46_ns_get_global_option(AO46NSOpenGLGlobalOption pname, GLint *param)
{
    if (!param) {
        return;
    }

    if (AO46ClientGetGlobalOption((CGLGlobalOption)pname, param) != kCGLNoError) {
        *param = 0;
    }
}

void NSOpenGLSetOption(AO46NSOpenGLGlobalOption pname, GLint param)
{
    ao46_ns_set_global_option(pname, param);
}

void NSOpenGLGetOption(AO46NSOpenGLGlobalOption pname, GLint *param)
{
    ao46_ns_get_global_option(pname, param);
}

void NSOpenGLGetVersion(GLint *major, GLint *minor)
{
    if (major) {
        *major = 4;
    }
    if (minor) {
        *minor = 6;
    }
}

void AO46NSOpenGLSetOption(AO46NSOpenGLGlobalOption pname, GLint param)
{
    ao46_ns_set_global_option(pname, param);
}

void AO46NSOpenGLGetOption(AO46NSOpenGLGlobalOption pname, GLint *param)
{
    ao46_ns_get_global_option(pname, param);
}

void AO46NSOpenGLGetVersion(GLint *major, GLint *minor)
{
    NSOpenGLGetVersion(major, minor);
}

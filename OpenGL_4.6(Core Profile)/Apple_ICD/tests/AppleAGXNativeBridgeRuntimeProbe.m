#import <dlfcn.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define AO46_SKIP_UNSUPPORTED_PROFILE 77
#define AO46_G16X_SUBMIT_ENCODING "v32@0:8^@16Q24"
#define AO46_G16X_FILL_COMMAND_BUFFER_ARGS_ENCODING \
   "v32@0:8^{IOGPUCommandQueueCommandBufferArgs=III(?=@?Q)(?=@?Q)IQ}16@24"

static void
report_candidate_class(const char *name)
{
   Class cls = objc_lookUpClass(name);

   if (!cls) {
      printf("Apple AGX bridge class probe: class=%s present=0\n", name);
      return;
   }

   Class superclass = class_getSuperclass(cls);
   printf("Apple AGX bridge class probe: class=%s present=1 superclass=%s\n",
          name, superclass ? class_getName(superclass) : "-");

   unsigned method_count = 0;
   Method *methods = class_copyMethodList(cls, &method_count);
   const unsigned limit = method_count;

   for (unsigned i = 0; i < limit; ++i) {
      printf("Apple AGX bridge class method: class=%s selector=%s encoding=%s\n",
             name, sel_getName(method_getName(methods[i])),
             method_getTypeEncoding(methods[i]));
   }

   free(methods);

   unsigned ivar_count = 0;
   Ivar *ivars = class_copyIvarList(cls, &ivar_count);
   for (unsigned i = 0; i < ivar_count; ++i) {
      printf("Apple AGX bridge class ivar: class=%s name=%s encoding=%s "
             "offset=%td\n", name, ivar_getName(ivars[i]),
             ivar_getTypeEncoding(ivars[i]), ivar_getOffset(ivars[i]));
   }

   free(ivars);
}

/* Read runtime method and ivar metadata only. The probe never creates an
 * IOGPU object, reads an ivar value, invokes a private selector, or submits
 * GPU work. */
int
main(void)
{
   const char *path =
      "/System/Library/PrivateFrameworks/IOGPU.framework/Versions/A/IOGPU";
   void *image = dlopen(path, RTLD_LAZY | RTLD_LOCAL);

   if (!image) {
      fprintf(stderr, "IOGPU is unavailable on this profile: %s\n", dlerror());
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   Class queue_class = objc_lookUpClass("IOGPUMetalCommandQueue");
   SEL selector = sel_registerName("submitCommandBuffers:count:");
   Method method = queue_class ? class_getInstanceMethod(queue_class, selector)
                               : NULL;
   const char *encoding = method ? method_getTypeEncoding(method) : NULL;
   SEL queue_init_selector = sel_registerName("initWithDevice:descriptor:");
   Method queue_init_method = queue_class
      ? class_getInstanceMethod(queue_class, queue_init_selector)
      : NULL;
   const char *queue_init_encoding = queue_init_method
      ? method_getTypeEncoding(queue_init_method)
      : NULL;
   Class command_buffer_class = objc_lookUpClass("IOGPUMetalCommandBuffer");
   SEL fill_selector =
      sel_registerName("fillCommandBufferArgs:commandQueue:");
   Method fill_method = command_buffer_class
      ? class_getInstanceMethod(command_buffer_class, fill_selector)
      : NULL;
   const char *fill_encoding =
      fill_method ? method_getTypeEncoding(fill_method) : NULL;
   SEL command_buffer_init_selector =
      sel_registerName("initWithQueue:retainedReferences:synchronousDebugMode:");
   Method command_buffer_init_method = command_buffer_class
      ? class_getInstanceMethod(command_buffer_class, command_buffer_init_selector)
      : NULL;
   const char *command_buffer_init_encoding = command_buffer_init_method
      ? method_getTypeEncoding(command_buffer_init_method)
      : NULL;

   if (!queue_class || !method || !encoding || !encoding[0]) {
      fputs("IOGPU command-queue submit metadata is unavailable on this profile\n",
            stderr);
      dlclose(image);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (strcmp(encoding, AO46_G16X_SUBMIT_ENCODING) != 0) {
      fprintf(stderr,
              "IOGPU command-queue submit encoding is unsupported: %s\n",
              encoding);
      dlclose(image);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!command_buffer_class || !fill_method || !fill_encoding ||
       strcmp(fill_encoding, AO46_G16X_FILL_COMMAND_BUFFER_ARGS_ENCODING) != 0) {
      fprintf(stderr,
              "IOGPU command-buffer argument-fill encoding is unsupported: %s\n",
              fill_encoding ? fill_encoding : "-");
      dlclose(image);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   if (!queue_init_encoding || !queue_init_encoding[0] ||
       !command_buffer_init_encoding || !command_buffer_init_encoding[0]) {
      fputs("IOGPU command initializer metadata is unavailable on this profile\n",
            stderr);
      dlclose(image);
      return AO46_SKIP_UNSUPPORTED_PROFILE;
   }

   printf("Apple AGX bridge runtime probe: class=IOGPUMetalCommandQueue "
          "selector=submitCommandBuffers:count: encoding=%s\n",
          encoding);
   printf("Apple AGX bridge runtime probe: class=IOGPUMetalCommandBuffer "
          "selector=fillCommandBufferArgs:commandQueue: encoding=%s\n",
          fill_encoding);
   printf("Apple AGX bridge runtime probe: class=IOGPUMetalCommandQueue "
          "selector=initWithDevice:descriptor: encoding=%s\n",
          queue_init_encoding);
   printf("Apple AGX bridge runtime probe: class=IOGPUMetalCommandBuffer "
          "selector=initWithQueue:retainedReferences:synchronousDebugMode: "
          "encoding=%s\n",
          command_buffer_init_encoding);

   if (getenv("AO46_AGX_BRIDGE_DISCOVER")) {
      static const char *const candidates[] = {
         "IOGPUMetalDevice",
         "IOGPUCommandQueue",
         "IOGPUMetalCommandQueue",
         "IOGPUCommandBuffer",
         "IOGPUMetalCommandBuffer",
         "IOGPUMetal4CommandAllocator",
         "IOGPUMetal4CommandQueue",
         "IOGPUMetal4CommandBuffer",
         "IOGPUMetalIndirectCommandBuffer",
         "IOGPUResource",
         "IOGPUMetalResource",
         "IOGPUMetalBuffer",
         "IOGPUMetalTexture",
      };

      for (unsigned i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i)
         report_candidate_class(candidates[i]);
   }

   dlclose(image);
   return 0;
}

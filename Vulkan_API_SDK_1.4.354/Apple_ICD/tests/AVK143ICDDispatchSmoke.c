#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vk_icd.h>

typedef VkResult(VKAPI_PTR *PFN_vkEnumerateInstanceVersionForSmoke)(
   uint32_t *pApiVersion);

static int
parse_expected_component(const char *value, uint32_t *out)
{
   char *end = NULL;
   unsigned long parsed = strtoul(value, &end, 10);

   if (value[0] == '\0' || end == NULL || *end != '\0' || parsed > UINT32_MAX)
      return 0;

   *out = (uint32_t)parsed;
   return 1;
}

int
main(int argc, char **argv)
{
   if (argc == 2 && strcmp(argv[1], "--headers-only") == 0) {
      if (VK_API_VERSION_1_4 != VK_MAKE_API_VERSION(0, 1, 4, 0)) {
         fputs("AVK143 Vulkan 1.4 standard header contract mismatched\n", stderr);
         return 1;
      }

      printf("AVK143 standard Vulkan headers: 1.4.%u\n", VK_HEADER_VERSION);
      return 0;
   }

   if (argc != 4) {
      fprintf(stderr, "usage: %s <icd-dylib> <expected-major> <expected-minor>\n",
              argv[0]);
      return 2;
   }

   uint32_t expected_major;
   uint32_t expected_minor;
   if (!parse_expected_component(argv[2], &expected_major) ||
       !parse_expected_component(argv[3], &expected_minor)) {
      fputs("AVK143 expected Vulkan version is invalid\n", stderr);
      return 2;
   }

   void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
   if (library == NULL) {
      fprintf(stderr, "AVK143 could not load ICD %s: %s\n", argv[1], dlerror());
      return 1;
   }

   PFN_vk_icdNegotiateLoaderICDInterfaceVersion negotiate =
      (PFN_vk_icdNegotiateLoaderICDInterfaceVersion)dlsym(
         library, "vk_icdNegotiateLoaderICDInterfaceVersion");
   PFN_vk_icdGetInstanceProcAddr get_instance_proc_addr =
      (PFN_vk_icdGetInstanceProcAddr)dlsym(library, "vk_icdGetInstanceProcAddr");

   if (negotiate == NULL || get_instance_proc_addr == NULL) {
      fputs("AVK143 ICD is missing the standard loader handshake exports\n", stderr);
      dlclose(library);
      return 1;
   }

   uint32_t loader_interface = CURRENT_LOADER_ICD_INTERFACE_VERSION;
   if (negotiate(&loader_interface) != VK_SUCCESS ||
       loader_interface < MIN_PHYS_DEV_EXTENSION_ICD_INTERFACE_VERSION) {
      fputs("AVK143 ICD rejected the standard loader interface\n", stderr);
      dlclose(library);
      return 1;
   }

   PFN_vkEnumerateInstanceVersionForSmoke enumerate_version =
      (PFN_vkEnumerateInstanceVersionForSmoke)get_instance_proc_addr(
         VK_NULL_HANDLE, "vkEnumerateInstanceVersion");
   if (enumerate_version == NULL) {
      fputs("AVK143 ICD does not return vkEnumerateInstanceVersion\n", stderr);
      dlclose(library);
      return 1;
   }

   uint32_t api_version = 0;
   if (enumerate_version(&api_version) != VK_SUCCESS ||
       VK_API_VERSION_MAJOR(api_version) != expected_major ||
       VK_API_VERSION_MINOR(api_version) != expected_minor) {
      fprintf(stderr,
              "AVK143 ICD reported Vulkan %u.%u.%u, expected %u.%u.x\n",
              VK_API_VERSION_MAJOR(api_version), VK_API_VERSION_MINOR(api_version),
              VK_API_VERSION_PATCH(api_version), expected_major, expected_minor);
      dlclose(library);
      return 1;
   }

   printf("AVK143 ICD loader interface %u, Vulkan %u.%u.%u\n",
          loader_interface, VK_API_VERSION_MAJOR(api_version),
          VK_API_VERSION_MINOR(api_version), VK_API_VERSION_PATCH(api_version));
   dlclose(library);
   return 0;
}

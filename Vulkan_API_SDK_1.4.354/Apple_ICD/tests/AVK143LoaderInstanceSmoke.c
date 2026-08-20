#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <vulkan/vulkan.h>

static int
check_result(const char *operation, VkResult result)
{
   if (result == VK_SUCCESS)
      return 1;

   fprintf(stderr, "AVK143 %s failed with VkResult %d\n", operation, result);
   return 0;
}

int
main(int argc, char **argv)
{
   if (argc != 2) {
      fprintf(stderr, "usage: %s <icd-manifest.json>\n", argv[0]);
      return 2;
   }

   if (setenv("VK_DRIVER_FILES", argv[1], 1) != 0) {
      perror("AVK143 could not select its ICD manifest");
      return 1;
   }

   uint32_t loader_version = VK_API_VERSION_1_0;
   if (!check_result("vkEnumerateInstanceVersion",
                     vkEnumerateInstanceVersion(&loader_version)))
      return 1;

   if (VK_API_VERSION_MAJOR(loader_version) != 1 ||
       VK_API_VERSION_MINOR(loader_version) < 4) {
      fprintf(stderr, "AVK143 loader reported Vulkan %u.%u.%u, expected 1.4.x\n",
              VK_API_VERSION_MAJOR(loader_version),
              VK_API_VERSION_MINOR(loader_version),
              VK_API_VERSION_PATCH(loader_version));
      return 1;
   }

   const VkApplicationInfo application_info = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "AVK143 Loader Smoke",
      .applicationVersion = 1,
      .pEngineName = "AVK143",
      .engineVersion = 1,
      .apiVersion = VK_API_VERSION_1_4,
   };
   const VkInstanceCreateInfo create_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &application_info,
   };

   VkInstance instance = VK_NULL_HANDLE;
   if (!check_result("vkCreateInstance",
                     vkCreateInstance(&create_info, NULL, &instance)))
      return 1;

   uint32_t physical_device_count = 0;
   const VkResult enumerate_result =
      vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL);
   vkDestroyInstance(instance, NULL);

   if (!check_result("vkEnumeratePhysicalDevices", enumerate_result))
      return 1;

   if (physical_device_count == 0) {
      fputs("AVK143 loader discovered the ICD but no physical device\n", stderr);
      return 1;
   }

   printf("AVK143 loader Vulkan %u.%u.%u, physical devices: %u\n",
          VK_API_VERSION_MAJOR(loader_version),
          VK_API_VERSION_MINOR(loader_version),
          VK_API_VERSION_PATCH(loader_version), physical_device_count);
   return 0;
}

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <vulkan/vulkan.h>

enum { AVK143_COMPUTE_RESULT = 0x4b524f4eU };

static int
check_result(const char *operation, VkResult result)
{
   if (result == VK_SUCCESS)
      return 1;

   fprintf(stderr, "AVK143 %s failed with VkResult %d\n", operation, result);
   return 0;
}

static uint32_t
find_compute_queue_family(VkPhysicalDevice physical_device)
{
   uint32_t queue_count = 0;
   vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, NULL);
   VkQueueFamilyProperties *queues =
      calloc(queue_count, sizeof(*queues));
   if (queues == NULL)
      return UINT32_MAX;

   vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, queues);
   uint32_t family = UINT32_MAX;
   for (uint32_t index = 0; index < queue_count; ++index) {
      if (queues[index].queueCount != 0 &&
          (queues[index].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0) {
         family = index;
         break;
      }
   }

   free(queues);
   return family;
}

static uint32_t
find_host_visible_memory_type(VkPhysicalDevice physical_device,
                              uint32_t type_bits)
{
   VkPhysicalDeviceMemoryProperties properties;
   vkGetPhysicalDeviceMemoryProperties(physical_device, &properties);

   for (uint32_t index = 0; index < properties.memoryTypeCount; ++index) {
      const VkMemoryPropertyFlags required = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
      if ((type_bits & (1u << index)) != 0 &&
          (properties.memoryTypes[index].propertyFlags & required) == required)
         return index;
   }

   return UINT32_MAX;
}

static uint32_t *
load_spirv(const char *path, size_t *size_out)
{
   FILE *file = fopen(path, "rb");
   if (file == NULL)
      return NULL;

   if (fseek(file, 0, SEEK_END) != 0) {
      fclose(file);
      return NULL;
   }

   const long file_size = ftell(file);
   if (file_size <= 0 || (file_size % 4) != 0 || fseek(file, 0, SEEK_SET) != 0) {
      fclose(file);
      return NULL;
   }

   uint32_t *code = malloc((size_t)file_size);
   if (code == NULL || fread(code, 1, (size_t)file_size, file) != (size_t)file_size) {
      free(code);
      fclose(file);
      return NULL;
   }

   fclose(file);
   *size_out = (size_t)file_size;
   return code;
}

int
main(int argc, char **argv)
{
   if (argc != 3) {
      fprintf(stderr, "usage: %s <icd-manifest.json> <compute.spv>\n", argv[0]);
      return 2;
   }

   if (setenv("VK_DRIVER_FILES", argv[1], 1) != 0) {
      perror("AVK143 could not select its ICD manifest");
      return 1;
   }

   const VkApplicationInfo application_info = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "AVK143 Compute Smoke",
      .applicationVersion = 1,
      .pEngineName = "AVK143",
      .engineVersion = 1,
      .apiVersion = VK_API_VERSION_1_4,
   };
   const VkInstanceCreateInfo instance_create_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &application_info,
   };

   VkInstance instance = VK_NULL_HANDLE;
   VkDevice device = VK_NULL_HANDLE;
   VkBuffer buffer = VK_NULL_HANDLE;
   VkDeviceMemory memory = VK_NULL_HANDLE;
   VkDescriptorSetLayout descriptor_set_layout = VK_NULL_HANDLE;
   VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
   VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
   VkPipeline pipeline = VK_NULL_HANDLE;
   VkShaderModule shader_module = VK_NULL_HANDLE;
   VkCommandPool command_pool = VK_NULL_HANDLE;
   VkFence fence = VK_NULL_HANDLE;
   uint32_t *spirv = NULL;
   int status = 1;

   if (!check_result("vkCreateInstance",
                     vkCreateInstance(&instance_create_info, NULL, &instance)))
      goto cleanup;

   uint32_t physical_device_count = 0;
   if (!check_result("vkEnumeratePhysicalDevices(count)",
                     vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL)) ||
       physical_device_count == 0)
      goto cleanup;

   VkPhysicalDevice *physical_devices =
      calloc(physical_device_count, sizeof(*physical_devices));
   if (physical_devices == NULL)
      goto cleanup;

   const VkResult enumerate_result = vkEnumeratePhysicalDevices(
      instance, &physical_device_count, physical_devices);
   if (!check_result("vkEnumeratePhysicalDevices(list)", enumerate_result)) {
      free(physical_devices);
      goto cleanup;
   }

   const VkPhysicalDevice physical_device = physical_devices[0];
   free(physical_devices);

   const uint32_t queue_family = find_compute_queue_family(physical_device);
   if (queue_family == UINT32_MAX) {
      fputs("AVK143 did not expose a compute-capable queue family\n", stderr);
      goto cleanup;
   }

   const float priority = 1.0f;
   const VkDeviceQueueCreateInfo queue_create_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = queue_family,
      .queueCount = 1,
      .pQueuePriorities = &priority,
   };
   const VkPhysicalDeviceVulkan13Features vulkan_13_features = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .synchronization2 = VK_TRUE,
   };
   const VkDeviceCreateInfo device_create_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &vulkan_13_features,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &queue_create_info,
   };
   if (!check_result("vkCreateDevice",
                     vkCreateDevice(physical_device, &device_create_info, NULL, &device)))
      goto cleanup;

   VkQueue queue = VK_NULL_HANDLE;
   vkGetDeviceQueue(device, queue_family, 0, &queue);

   const VkBufferCreateInfo buffer_create_info = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = sizeof(uint32_t),
      .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   if (!check_result("vkCreateBuffer",
                     vkCreateBuffer(device, &buffer_create_info, NULL, &buffer)))
      goto cleanup;

   VkMemoryRequirements memory_requirements;
   vkGetBufferMemoryRequirements(device, buffer, &memory_requirements);
   const uint32_t memory_type = find_host_visible_memory_type(
      physical_device, memory_requirements.memoryTypeBits);
   if (memory_type == UINT32_MAX) {
      fputs("AVK143 did not expose host-visible buffer memory\n", stderr);
      goto cleanup;
   }

   const VkMemoryAllocateInfo allocate_info = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = memory_requirements.size,
      .memoryTypeIndex = memory_type,
   };
   if (!check_result("vkAllocateMemory",
                     vkAllocateMemory(device, &allocate_info, NULL, &memory)) ||
       !check_result("vkBindBufferMemory",
                     vkBindBufferMemory(device, buffer, memory, 0)))
      goto cleanup;

   void *mapped = NULL;
   if (!check_result("vkMapMemory(initial)",
                     vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped)))
      goto cleanup;
   *(uint32_t *)mapped = 0;
   vkUnmapMemory(device, memory);

   const VkDescriptorSetLayoutBinding binding = {
      .binding = 0,
      .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
      .descriptorCount = 1,
      .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
   };
   const VkDescriptorSetLayoutCreateInfo descriptor_set_layout_create_info = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = 1,
      .pBindings = &binding,
   };
   if (!check_result("vkCreateDescriptorSetLayout",
                     vkCreateDescriptorSetLayout(device, &descriptor_set_layout_create_info,
                                                  NULL, &descriptor_set_layout)))
      goto cleanup;

   const VkPipelineLayoutCreateInfo pipeline_layout_create_info = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = 1,
      .pSetLayouts = &descriptor_set_layout,
   };
   if (!check_result("vkCreatePipelineLayout",
                     vkCreatePipelineLayout(device, &pipeline_layout_create_info,
                                            NULL, &pipeline_layout)))
      goto cleanup;

   size_t spirv_size = 0;
   spirv = load_spirv(argv[2], &spirv_size);
   if (spirv == NULL) {
      fputs("AVK143 could not read the compute SPIR-V module\n", stderr);
      goto cleanup;
   }

   const VkShaderModuleCreateInfo shader_module_create_info = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = spirv_size,
      .pCode = spirv,
   };
   if (!check_result("vkCreateShaderModule",
                     vkCreateShaderModule(device, &shader_module_create_info,
                                          NULL, &shader_module)))
      goto cleanup;

   const VkPipelineShaderStageCreateInfo shader_stage = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage = VK_SHADER_STAGE_COMPUTE_BIT,
      .module = shader_module,
      .pName = "main",
   };
   const VkComputePipelineCreateInfo compute_pipeline_create_info = {
      .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
      .stage = shader_stage,
      .layout = pipeline_layout,
   };
   if (!check_result("vkCreateComputePipelines",
                     vkCreateComputePipelines(device, VK_NULL_HANDLE, 1,
                                              &compute_pipeline_create_info,
                                              NULL, &pipeline)))
      goto cleanup;

   const VkDescriptorPoolSize descriptor_pool_size = {
      .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
      .descriptorCount = 1,
   };
   const VkDescriptorPoolCreateInfo descriptor_pool_create_info = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
      .maxSets = 1,
      .poolSizeCount = 1,
      .pPoolSizes = &descriptor_pool_size,
   };
   if (!check_result("vkCreateDescriptorPool",
                     vkCreateDescriptorPool(device, &descriptor_pool_create_info,
                                            NULL, &descriptor_pool)))
      goto cleanup;

   const VkDescriptorSetAllocateInfo descriptor_set_allocate_info = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool = descriptor_pool,
      .descriptorSetCount = 1,
      .pSetLayouts = &descriptor_set_layout,
   };
   VkDescriptorSet descriptor_set = VK_NULL_HANDLE;
   if (!check_result("vkAllocateDescriptorSets",
                     vkAllocateDescriptorSets(device, &descriptor_set_allocate_info,
                                              &descriptor_set)))
      goto cleanup;

   const VkDescriptorBufferInfo buffer_info = {
      .buffer = buffer,
      .offset = 0,
      .range = sizeof(uint32_t),
   };
   const VkWriteDescriptorSet descriptor_write = {
      .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      .dstSet = descriptor_set,
      .dstBinding = 0,
      .descriptorCount = 1,
      .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
      .pBufferInfo = &buffer_info,
   };
   vkUpdateDescriptorSets(device, 1, &descriptor_write, 0, NULL);

   const VkCommandPoolCreateInfo command_pool_create_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = queue_family,
   };
   if (!check_result("vkCreateCommandPool",
                     vkCreateCommandPool(device, &command_pool_create_info,
                                         NULL, &command_pool)))
      goto cleanup;

   const VkCommandBufferAllocateInfo command_buffer_allocate_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = command_pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1,
   };
   VkCommandBuffer command_buffer = VK_NULL_HANDLE;
   if (!check_result("vkAllocateCommandBuffers",
                     vkAllocateCommandBuffers(device, &command_buffer_allocate_info,
                                              &command_buffer)))
      goto cleanup;

   const VkCommandBufferBeginInfo command_buffer_begin_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   if (!check_result("vkBeginCommandBuffer",
                     vkBeginCommandBuffer(command_buffer, &command_buffer_begin_info)))
      goto cleanup;

   vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
   vkCmdBindDescriptorSets(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                           pipeline_layout, 0, 1, &descriptor_set, 0, NULL);
   vkCmdDispatch(command_buffer, 1, 1, 1);

   const VkMemoryBarrier2 write_to_host = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
      .srcStageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT,
      .srcAccessMask = VK_ACCESS_2_SHADER_WRITE_BIT,
      .dstStageMask = VK_PIPELINE_STAGE_2_HOST_BIT,
      .dstAccessMask = VK_ACCESS_2_HOST_READ_BIT,
   };
   const VkDependencyInfo dependency_info = {
      .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
      .memoryBarrierCount = 1,
      .pMemoryBarriers = &write_to_host,
   };
   vkCmdPipelineBarrier2(command_buffer, &dependency_info);

   if (!check_result("vkEndCommandBuffer", vkEndCommandBuffer(command_buffer)))
      goto cleanup;

   const VkFenceCreateInfo fence_create_info = {
      .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
   };
   if (!check_result("vkCreateFence", vkCreateFence(device, &fence_create_info,
                                                       NULL, &fence)))
      goto cleanup;

   const VkCommandBufferSubmitInfo command_buffer_submit_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
      .commandBuffer = command_buffer,
   };
   const VkSubmitInfo2 submit_info = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
      .commandBufferInfoCount = 1,
      .pCommandBufferInfos = &command_buffer_submit_info,
   };
   if (!check_result("vkQueueSubmit2", vkQueueSubmit2(queue, 1, &submit_info,
                                                         fence)) ||
       !check_result("vkWaitForFences",
                     vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL)))
      goto cleanup;

   if (!check_result("vkMapMemory(result)",
                     vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped)))
      goto cleanup;
   const VkMappedMemoryRange result_range = {
      .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
      .memory = memory,
      .offset = 0,
      .size = VK_WHOLE_SIZE,
   };
   if (!check_result("vkInvalidateMappedMemoryRanges",
                     vkInvalidateMappedMemoryRanges(device, 1, &result_range))) {
      vkUnmapMemory(device, memory);
      goto cleanup;
   }

   const uint32_t result = *(const uint32_t *)mapped;
   vkUnmapMemory(device, memory);
   if (result != AVK143_COMPUTE_RESULT) {
      fprintf(stderr, "AVK143 compute returned 0x%08x, expected 0x%08x\n",
              result, AVK143_COMPUTE_RESULT);
      goto cleanup;
   }

   printf("AVK143 compute wrote 0x%08x through Mesa KosmicKrisp\n", result);
   status = 0;

cleanup:
   free(spirv);
   if (device != VK_NULL_HANDLE)
      vkDeviceWaitIdle(device);
   if (fence != VK_NULL_HANDLE)
      vkDestroyFence(device, fence, NULL);
   if (command_pool != VK_NULL_HANDLE)
      vkDestroyCommandPool(device, command_pool, NULL);
   if (descriptor_pool != VK_NULL_HANDLE)
      vkDestroyDescriptorPool(device, descriptor_pool, NULL);
   if (pipeline != VK_NULL_HANDLE)
      vkDestroyPipeline(device, pipeline, NULL);
   if (shader_module != VK_NULL_HANDLE)
      vkDestroyShaderModule(device, shader_module, NULL);
   if (pipeline_layout != VK_NULL_HANDLE)
      vkDestroyPipelineLayout(device, pipeline_layout, NULL);
   if (descriptor_set_layout != VK_NULL_HANDLE)
      vkDestroyDescriptorSetLayout(device, descriptor_set_layout, NULL);
   if (buffer != VK_NULL_HANDLE)
      vkDestroyBuffer(device, buffer, NULL);
   if (memory != VK_NULL_HANDLE)
      vkFreeMemory(device, memory, NULL);
   if (device != VK_NULL_HANDLE)
      vkDestroyDevice(device, NULL);
   if (instance != VK_NULL_HANDLE)
      vkDestroyInstance(instance, NULL);
   return status;
}

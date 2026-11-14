#include "first_frame.h"

#include <SDL3/SDL_log.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <vector>

namespace {

bool Check(VkResult result, const char* operation) {
  if (result == VK_SUCCESS) {
    return true;
  }
  SDL_Log("MoltenVK first frame: %s returned %d", operation, result);
  return false;
}

}  // namespace

FirstFrame::~FirstFrame() {
  if (!device_) {
    return;
  }
  vkDeviceWaitIdle(device_);
  vkDestroySemaphore(device_, cleared_, nullptr);
  vkDestroySemaphore(device_, acquired_, nullptr);
  vkDestroyCommandPool(device_, pool_, nullptr);
  vkDestroySwapchainKHR(device_, swapchain_, nullptr);
  vkDestroyDevice(device_, nullptr);
}

bool FirstFrame::Present(VkPhysicalDevice physical, uint32_t family, VkSurfaceKHR surface) {
  uint32_t count = 0;
  if (!Check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr),
             "enumerate device extension count")) {
    return false;
  }
  std::vector<VkExtensionProperties> available(count);
  if (!Check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, available.data()),
             "enumerate device extensions")) {
    return false;
  }
  available.resize(count);
  std::vector<const char*> enabled;
  for (const auto& extension : available) {
    if (std::strcmp(extension.extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0 ||
        std::strcmp(extension.extensionName, "VK_KHR_portability_subset") == 0) {
      enabled.push_back(extension.extensionName);
    }
  }
  const auto swapchain_extension = std::find_if(enabled.begin(), enabled.end(), [](const char* name) {
    return std::strcmp(name, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0;
  });
  if (swapchain_extension == enabled.end()) {
    SDL_Log("MoltenVK first frame: VK_KHR_swapchain unavailable");
    return false;
  }

  VkSurfaceCapabilitiesKHR caps{};
  if (!Check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps),
             "query surface capabilities")) {
    return false;
  }
  const VkExtent2D extent = caps.currentExtent;
  if (!extent.width || !extent.height || extent.width == std::numeric_limits<uint32_t>::max() ||
      !(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT) ||
      !(caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)) {
    SDL_Log("MoltenVK first frame: unsupported drawable (%ux%u, usage=%#x, alpha=%#x)",
            extent.width, extent.height, caps.supportedUsageFlags, caps.supportedCompositeAlpha);
    return false;
  }
  if (!Check(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, nullptr),
             "query surface format count") || !count) {
    return false;
  }
  std::vector<VkSurfaceFormatKHR> formats(count);
  if (!Check(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, formats.data()),
             "query surface formats") || !count) {
    return false;
  }

  const float priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  queue_info.queueFamilyIndex = family;
  queue_info.queueCount = 1;
  queue_info.pQueuePriorities = &priority;
  VkDeviceCreateInfo device_info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  device_info.queueCreateInfoCount = 1;
  device_info.pQueueCreateInfos = &queue_info;
  device_info.enabledExtensionCount = static_cast<uint32_t>(enabled.size());
  device_info.ppEnabledExtensionNames = enabled.data();
  if (!Check(vkCreateDevice(physical, &device_info, nullptr, &device_), "vkCreateDevice")) {
    return false;
  }
  VkQueue queue = VK_NULL_HANDLE;
  vkGetDeviceQueue(device_, family, 0, &queue);

  VkSwapchainCreateInfoKHR swapchain_info{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
  swapchain_info.surface = surface;
  swapchain_info.minImageCount = caps.minImageCount;
  swapchain_info.imageFormat = formats.front().format;
  swapchain_info.imageColorSpace = formats.front().colorSpace;
  swapchain_info.imageExtent = extent;
  swapchain_info.imageArrayLayers = 1;
  swapchain_info.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
  swapchain_info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
  swapchain_info.preTransform = caps.currentTransform;
  swapchain_info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
  swapchain_info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
  swapchain_info.clipped = VK_TRUE;
  if (!Check(vkCreateSwapchainKHR(device_, &swapchain_info, nullptr, &swapchain_),
             "vkCreateSwapchainKHR") ||
      !Check(vkGetSwapchainImagesKHR(device_, swapchain_, &count, nullptr), "query image count")) {
    return false;
  }
  std::vector<VkImage> images(count);
  if (!Check(vkGetSwapchainImagesKHR(device_, swapchain_, &count, images.data()), "query images")) {
    return false;
  }

  VkCommandPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
  pool_info.queueFamilyIndex = family;
  if (!Check(vkCreateCommandPool(device_, &pool_info, nullptr, &pool_), "vkCreateCommandPool")) {
    return false;
  }
  VkCommandBufferAllocateInfo allocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
  allocation.commandPool = pool_;
  allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  allocation.commandBufferCount = 1;
  VkCommandBuffer command = VK_NULL_HANDLE;
  VkSemaphoreCreateInfo semaphore_info{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  if (!Check(vkAllocateCommandBuffers(device_, &allocation, &command), "allocate command buffer") ||
      !Check(vkCreateSemaphore(device_, &semaphore_info, nullptr, &acquired_), "create acquire semaphore") ||
      !Check(vkCreateSemaphore(device_, &semaphore_info, nullptr, &cleared_), "create clear semaphore")) {
    return false;
  }

  uint32_t image_index = 0;
  VkResult result = vkAcquireNextImageKHR(device_, swapchain_, 100'000'000, acquired_,
                                         VK_NULL_HANDLE, &image_index);
  if (result != VK_SUBOPTIMAL_KHR && !Check(result, "vkAcquireNextImageKHR")) {
    return false;
  }
  VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  if (!Check(vkBeginCommandBuffer(command, &begin), "vkBeginCommandBuffer")) {
    return false;
  }
  VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
  barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
  barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  barrier.image = images[image_index];
  barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       0, 0, nullptr, 0, nullptr, 1, &barrier);
  const VkClearColorValue blue{{0.02f, 0.24f, 0.85f, 1.0f}};
  vkCmdClearColorImage(command, barrier.image, barrier.newLayout, &blue, 1,
                       &barrier.subresourceRange);
  barrier.oldLayout = barrier.newLayout;
  barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  barrier.dstAccessMask = 0;
  vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                       0, 0, nullptr, 0, nullptr, 1, &barrier);
  if (!Check(vkEndCommandBuffer(command), "vkEndCommandBuffer")) {
    return false;
  }
  const VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
  submit.waitSemaphoreCount = 1;
  submit.pWaitSemaphores = &acquired_;
  submit.pWaitDstStageMask = &wait_stage;
  submit.commandBufferCount = 1;
  submit.pCommandBuffers = &command;
  submit.signalSemaphoreCount = 1;
  submit.pSignalSemaphores = &cleared_;
  if (!Check(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit")) {
    return false;
  }

  VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
  present.waitSemaphoreCount = 1;
  present.pWaitSemaphores = &cleared_;
  present.swapchainCount = 1;
  present.pSwapchains = &swapchain_;
  present.pImageIndices = &image_index;
  result = vkQueuePresentKHR(queue, &present);
  if (result != VK_SUBOPTIMAL_KHR && !Check(result, "vkQueuePresentKHR")) {
    return false;
  }
  SDL_Log("MoltenVK first frame: QUEUED (%ux%u, result=%d)", extent.width, extent.height, result);
  return true;
}

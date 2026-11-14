#pragma once

#include <vulkan/vulkan.h>

struct FirstFrame {
  FirstFrame() = default;
  FirstFrame(const FirstFrame&) = delete;
  FirstFrame& operator=(const FirstFrame&) = delete;
  ~FirstFrame();

  bool Present(VkPhysicalDevice physical, uint32_t family, VkSurfaceKHR surface);

 private:
  VkDevice device_ = VK_NULL_HANDLE;
  VkSwapchainKHR swapchain_ = VK_NULL_HANDLE;
  VkCommandPool pool_ = VK_NULL_HANDLE;
  VkSemaphore acquired_ = VK_NULL_HANDLE;
  VkSemaphore cleared_ = VK_NULL_HANDLE;
};

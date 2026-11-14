#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>
#define SDL_MAIN_USE_CALLBACKS
#include <SDL3/SDL_main.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

#include <rex/system/ios_guest_backing.h>

#include "first_frame.h"

#include <cerrno>
#include <cstring>
#include <memory>
#include <sys/mman.h>
#include <vector>

namespace {

struct Probe {
  SDL_Window* window = nullptr;
  SDL_MetalView view = nullptr;
  VkInstance instance = VK_NULL_HANDLE;
  VkSurfaceKHR surface = VK_NULL_HANDLE;
  VkPhysicalDevice physical = VK_NULL_HANDLE;
  uint32_t queue_family = 0;
  bool prerequisites_ok = false;
  bool attempted = false;
  std::unique_ptr<FirstFrame> frame;
};

bool CheckMachAliases() {
  // Match the runtime's reservation span and its physical alias offsets.
  const size_t page = vm_page_size;
  constexpr size_t span = 0x120000000ull;
  constexpr size_t physical = 0x100000000ull;
  rex::memory::ios::GuestBacking backing;
  const kern_return_t created = backing.Create(span + page);
  if (created != KERN_SUCCESS) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "mach_make_memory_entry_64: %d", created);
    return false;
  }

  auto* base = static_cast<char*>(mmap(nullptr, span, PROT_NONE,
                                      MAP_PRIVATE | MAP_ANON, -1, 0));
  if (base == MAP_FAILED) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "mmap: %s", strerror(errno));
    return false;
  }

  constexpr size_t guest_offset = 0x1000;
  const size_t aligned_offset = guest_offset / page * page;
  const size_t bias = guest_offset - aligned_offset;
  char* low_alias = base + 0xE0000000ull;
  char* raw_alias = base + physical;
  const kern_return_t low_result = backing.MapReserved(low_alias, page, physical + aligned_offset);
  const kern_return_t raw_result = backing.MapReserved(raw_alias, aligned_offset + page, physical);
  bool shared = false;
  if (low_result == KERN_SUCCESS && raw_result == KERN_SUCCESS) {
    volatile char* low_byte = low_alias + bias;
    volatile char* raw_byte = raw_alias + guest_offset;
    *low_byte = 42;
    shared = *raw_byte == 42;
    *raw_byte = 17;
    shared = shared && *low_byte == 17;
  }
  munmap(base, span);
  SDL_Log("Mach aliases: %s (page=%zu, bias=%zu, map=%d/%d)",
          shared ? "PASS" : "FAIL", page, bias, low_result, raw_result);
  return shared;
}

bool CheckSandbox() {
  NSFileManager* manager = NSFileManager.defaultManager;
  NSURL* documents = [manager URLsForDirectory:NSDocumentDirectory
                                     inDomains:NSUserDomainMask].firstObject;
  if (!documents) {
    SDL_Log("Sandbox Documents: FAIL (no URL)");
    return false;
  }
  NSURL* state = [documents URLByAppendingPathComponent:@"PinyonShiftProbe" isDirectory:YES];
  NSURL* marker = [state URLByAppendingPathComponent:@"probe-state.txt" isDirectory:NO];
  NSError* error = nil;
  NSData* previous = [NSData dataWithContentsOfURL:marker];
  NSData* expected = [@"Pinyon Shift iOS probe\n" dataUsingEncoding:NSUTF8StringEncoding];
  if (![manager createDirectoryAtURL:state withIntermediateDirectories:YES attributes:nil
                              error:&error] ||
      ![expected writeToURL:marker options:NSDataWritingAtomic error:&error]) {
    SDL_Log("Sandbox Documents: FAIL (%s)", error.localizedDescription.UTF8String);
    return false;
  }
  const bool read_back = [expected isEqualToData:[NSData dataWithContentsOfURL:marker]];
  SDL_Log("Sandbox Documents: %s (persisted from previous launch: %s)",
          read_back ? "PASS" : "FAIL", [expected isEqualToData:previous] ? "yes" : "no");
  return read_back;
}

bool CheckVulkan(Probe& probe, const CAMetalLayer* layer) {
  uint32_t count = 0;
  if (vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr) != VK_SUCCESS) {
    return false;
  }
  std::vector<VkExtensionProperties> available(count);
  if (vkEnumerateInstanceExtensionProperties(nullptr, &count, available.data()) != VK_SUCCESS) {
    return false;
  }

  const char* extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME,
                              VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
  VkInstanceCreateInfo instance_info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
  instance_info.enabledExtensionCount = 2;
  instance_info.ppEnabledExtensionNames = extensions;
  for (const auto& extension : available) {
    if (strcmp(extension.extensionName, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0) {
      instance_info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
      ++instance_info.enabledExtensionCount;
      break;
    }
  }

  uint32_t api_version = 0;
  const VkResult api_result = vkEnumerateInstanceVersion(&api_version);
  SDL_Log("MoltenVK API version: %u.%u.%u (result=%d)", VK_API_VERSION_MAJOR(api_version),
          VK_API_VERSION_MINOR(api_version), VK_API_VERSION_PATCH(api_version), api_result);
  if (api_result != VK_SUCCESS || api_version < VK_API_VERSION_1_3) {
    return false;
  }
  VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
  application.pApplicationName = "Pinyon Shift iOS Probe";
  application.apiVersion = VK_API_VERSION_1_3;
  instance_info.pApplicationInfo = &application;

  VkResult result = vkCreateInstance(&instance_info, nullptr, &probe.instance);
  if (result != VK_SUCCESS) {
    SDL_Log("vkCreateInstance: %d", result);
    return false;
  }
  auto create_surface = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
      vkGetInstanceProcAddr(probe.instance, "vkCreateMetalSurfaceEXT"));
  if (!create_surface) {
    SDL_Log("vkCreateMetalSurfaceEXT unavailable");
    return false;
  }
  VkMetalSurfaceCreateInfoEXT surface_info{VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
  surface_info.pLayer = layer;
  result = create_surface(probe.instance, &surface_info, nullptr, &probe.surface);
  if (result != VK_SUCCESS) {
    SDL_Log("vkCreateMetalSurfaceEXT: %d", result);
    return false;
  }

  if (vkEnumeratePhysicalDevices(probe.instance, &count, nullptr) != VK_SUCCESS || count == 0) {
    SDL_Log("No Vulkan physical devices");
    return false;
  }
  std::vector<VkPhysicalDevice> devices(count);
  if (vkEnumeratePhysicalDevices(probe.instance, &count, devices.data()) != VK_SUCCESS) {
    return false;
  }
  devices.resize(count);
  for (VkPhysicalDevice device : devices) {
    VkPhysicalDeviceProperties properties{};
    vkGetPhysicalDeviceProperties(device, &properties);
    uint32_t queue_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, nullptr);
    std::vector<VkQueueFamilyProperties> queues(queue_count);
    vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, queues.data());
    for (uint32_t i = 0; i < queue_count; ++i) {
      VkBool32 present = VK_FALSE;
      result = vkGetPhysicalDeviceSurfaceSupportKHR(device, i, probe.surface, &present);
      if (result == VK_SUCCESS && present && (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) {
        SDL_Log("MoltenVK surface: PASS (%s, graphics/present queue %u)", properties.deviceName, i);
        probe.physical = device;
        probe.queue_family = i;
        return true;
      }
    }
  }
  SDL_Log("MoltenVK surface: FAIL (no graphics/present queue)");
  return false;
}

}  // namespace

SDL_AppResult SDL_AppInit(void** appstate, int, char**) {
  auto* probe = new Probe;
  *appstate = probe;
  if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD)) {
    SDL_Log("SDL_Init: %s", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  SDL_Log("SDL video driver: %s", SDL_GetCurrentVideoDriver());
  probe->window = SDL_CreateWindow("Pinyon Shift iOS Probe", 1280, 720,
                                  SDL_WINDOW_METAL | SDL_WINDOW_FULLSCREEN);
  if (!probe->window) {
    SDL_Log("SDL_CreateWindow: %s", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  probe->view = SDL_Metal_CreateView(probe->window);
  if (!probe->view) {
    SDL_Log("SDL_Metal_CreateView: %s", SDL_GetError());
    return SDL_APP_FAILURE;
  }
  CAMetalLayer* layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(probe->view);
  const bool sandbox_ok = CheckSandbox();
  const bool mach_ok = CheckMachAliases();
  const bool vulkan_ok = layer && CheckVulkan(*probe, layer);
  probe->prerequisites_ok = sandbox_ok && mach_ok && vulkan_ok;
  return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void*, SDL_Event* event) {
  switch (event->type) {
    case SDL_EVENT_QUIT:
      return SDL_APP_SUCCESS;
    case SDL_EVENT_FINGER_DOWN:
      SDL_Log("SDL touch: %f, %f", event->tfinger.x, event->tfinger.y);
      break;
    case SDL_EVENT_GAMEPAD_ADDED:
      SDL_Log("SDL gamepad detected: %u", event->gdevice.which);
      break;
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
    case SDL_EVENT_DID_ENTER_FOREGROUND:
      SDL_Log("SDL lifecycle: %s", event->type == SDL_EVENT_WILL_ENTER_BACKGROUND
                                      ? "background" : "foreground");
      break;
  }
  return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppIterate(void* appstate) {
  auto& probe = *static_cast<Probe*>(appstate);
  if (!probe.attempted) {
    probe.attempted = true;
    bool queued = false;
    if (probe.physical) {
      probe.frame = std::make_unique<FirstFrame>();
      queued = probe.frame->Present(probe.physical, probe.queue_family, probe.surface);
    }
    SDL_Log("Pinyon iOS probe: %s", probe.prerequisites_ok && queued ? "PASS" : "FAIL");
  }
  return SDL_APP_CONTINUE;
}

void SDL_AppQuit(void* appstate, SDL_AppResult) {
  auto* probe = static_cast<Probe*>(appstate);
  probe->frame.reset();
  if (probe->surface) {
    vkDestroySurfaceKHR(probe->instance, probe->surface, nullptr);
  }
  if (probe->instance) {
    vkDestroyInstance(probe->instance, nullptr);
  }
  if (probe->view) {
    SDL_Metal_DestroyView(probe->view);
  }
  if (probe->window) {
    SDL_DestroyWindow(probe->window);
  }
  delete probe;
}

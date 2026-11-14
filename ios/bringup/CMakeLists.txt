cmake_minimum_required(VERSION 3.28)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS" OR NOT CMAKE_GENERATOR STREQUAL "Xcode")
    message(FATAL_ERROR "Configure this target with -G Xcode -DCMAKE_SYSTEM_NAME=iOS.")
endif()
project(PinyonShiftIOS LANGUAGES C CXX OBJCXX)

set(MOLTENVK_XCFRAMEWORK "" CACHE PATH "Path to the static iOS MoltenVK.xcframework")
if(NOT EXISTS "${MOLTENVK_XCFRAMEWORK}/Info.plist")
    message(FATAL_ERROR "Set MOLTENVK_XCFRAMEWORK to the static MoltenVK.xcframework.")
endif()

get_filename_component(SDK "${CMAKE_CURRENT_SOURCE_DIR}/../../thirdparty/shiftglue-sdk" ABSOLUTE)
set(DEPS "${SDK}/thirdparty")
foreach(required sdl3/CMakeLists.txt vulkan-headers/include/vulkan/vulkan.h)
    if(NOT EXISTS "${DEPS}/${required}")
        message(FATAL_ERROR "Initialize ShiftGlue's dependencies. Missing ${required}.")
    endif()
endforeach()

set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory("${DEPS}/sdl3" sdl3 EXCLUDE_FROM_ALL)

add_executable(pinyon_ios_probe MACOSX_BUNDLE probe.mm first_frame.cpp)
set_target_properties(pinyon_ios_probe PROPERTIES
    OUTPUT_NAME "PinyonShiftProbe"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.pinyonshift.iosprobe"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED YES
    OBJCXX_STANDARD 17
    OBJCXX_STANDARD_REQUIRED YES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    XCODE_GENERATE_SCHEME YES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)
target_include_directories(pinyon_ios_probe PRIVATE
    "${SDK}/include" "${DEPS}/vulkan-headers/include")
target_link_libraries(pinyon_ios_probe PRIVATE
    SDL3::SDL3-static "${MOLTENVK_XCFRAMEWORK}"
    "-framework Foundation" "-framework Metal" "-framework QuartzCore"
    "-framework CoreGraphics" "-framework IOSurface" "-framework UIKit")

# Pitch Shift for Windows: the sound engine (PitchShiftEngine.dll), the helper tool (PitchShiftTool.exe)
# and the tests. The sound math in engine/dsp has no Windows code, so its tests also build on the Mac.
#
#   Windows:  cmake -S windows -B build -A x64   (or -A ARM64)
#             cmake --build build --config Release
#   Mac:      cmake -S windows -B build-mac && cmake --build build-mac && ctest --test-dir build-mac
cmake_minimum_required(VERSION 3.24)
project(PitchShiftWindows VERSION 2.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Build the C++ runtime into each file (/MT), so people don't need to install anything extra.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
if(MSVC)
  add_compile_options(/utf-8 /permissive- /EHsc /W3)
endif()
if(WIN32)
  enable_language(RC)
  add_compile_definitions(UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN _USE_MATH_DEFINES _WIN32_WINNT=0x0A00)
endif()

include(FetchContent)
enable_testing()

# ---------- Outside code (pinned by hash) ----------

# Rubber Band 4.0.0 (GPL). On Windows it is compiled straight in from its one-file build.
# On the Mac the tests use the copy from Homebrew (brew install rubberband).
option(PS_SYSTEM_RUBBERBAND "Use the Rubber Band library installed on this computer" ${APPLE})
if(PS_SYSTEM_RUBBERBAND)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(RUBBERBAND REQUIRED IMPORTED_TARGET rubberband>=4.0.0)
  add_library(rubberband INTERFACE)
  target_link_libraries(rubberband INTERFACE PkgConfig::RUBBERBAND)
else()
  FetchContent_Declare(rubberband_src
    URL https://github.com/breakfastquay/rubberband/archive/refs/tags/v4.0.0.tar.gz
    URL_HASH SHA256=24300f48a8014b7c863b573a9647e61b1b19b37875e2cdd92005e64c6424d266
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(rubberband_src)
  add_library(rubberband STATIC ${rubberband_src_SOURCE_DIR}/single/RubberBandSingle.cpp)
  target_include_directories(rubberband SYSTEM PUBLIC ${rubberband_src_SOURCE_DIR})
  # RUBBERBAND_STATIC: keep Rubber Band's own functions private to our files.
  target_compile_definitions(rubberband PUBLIC RUBBERBAND_STATIC)
  if(MSVC)
    target_compile_options(rubberband PRIVATE /W0 /bigobj)
  else()
    target_compile_options(rubberband PRIVATE -w)
  endif()
  if(APPLE)
    target_link_libraries(rubberband PUBLIC "-framework Accelerate")
  endif()
endif()

# Small one-file helpers: doctest (tests) and nlohmann/json (reading and writing JSON).
set(PS_THIRD_PARTY ${CMAKE_BINARY_DIR}/third_party)
file(DOWNLOAD https://raw.githubusercontent.com/doctest/doctest/v2.5.3/doctest/doctest.h
  ${PS_THIRD_PARTY}/doctest/doctest.h
  EXPECTED_HASH SHA256=cfd518a3ef90f67e1f3ba514df23fb3627437de1a2feeba78cf5062a40021421)
file(DOWNLOAD https://github.com/nlohmann/json/releases/download/v3.12.0/json.hpp
  ${PS_THIRD_PARTY}/nlohmann/json.hpp
  EXPECTED_HASH SHA256=aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63)

# ---------- Advanced processing: the Mac app's own engine, shared (not copied) ----------

# ../Sources/Advanced is the same C++ the Mac app uses. On the Mac it uses Apple's Accelerate for its FFT;
# elsewhere a small FFT inside the same file (see AdvancedChain.cpp).
set(PS_ADVANCED_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../Sources/Advanced)
add_library(ps_advanced STATIC ${PS_ADVANCED_DIR}/AdvancedChain.cpp)
target_include_directories(ps_advanced PUBLIC ${PS_ADVANCED_DIR})
target_link_libraries(ps_advanced PUBLIC rubberband)
if(MSVC)
  # The Mac code mixes float and double freely; these warnings (number type changes) are expected there.
  target_compile_options(ps_advanced PRIVATE /wd4244 /wd4267 /wd4305)
endif()
if(APPLE)
  target_link_libraries(ps_advanced PUBLIC "-framework Accelerate")
endif()
# Checks on the Mac: -DPS_PORTABLE_FFT=ON uses the Windows FFT path there too.
option(PS_PORTABLE_FFT "Use the portable FFT in Advanced processing on the Mac too" OFF)
if(PS_PORTABLE_FFT)
  target_compile_definitions(ps_advanced PRIVATE ADVANCED_PORTABLE_FFT)
endif()

# ---------- Sound math (no Windows code) ----------

add_library(ps_dsp STATIC
  engine/dsp/advanced_shifter.cpp
  engine/dsp/analysis.cpp
  engine/dsp/booster.cpp
  engine/dsp/cushion.cpp
  engine/dsp/drift_buffer.cpp
  engine/dsp/music_shifter.cpp
  engine/dsp/voice_shifter.cpp
  engine/dsp/wav.cpp)
target_include_directories(ps_dsp PUBLIC engine)
target_link_libraries(ps_dsp PUBLIC rubberband ps_advanced)

add_executable(dsp_tests tests/dsp_tests.cpp)
target_include_directories(dsp_tests PRIVATE ${PS_THIRD_PARTY})
target_link_libraries(dsp_tests PRIVATE ps_dsp)
add_test(NAME dsp_tests COMMAND dsp_tests)

# ---------- Windows sound engine, the app's DLL, and the helper tool ----------

if(WIN32)
  add_library(ps_win STATIC
    engine/win/apps.cpp
    engine/win/cable.cpp
    engine/win/capture.cpp
    engine/win/com.cpp
    engine/win/devices.cpp
    engine/win/mic_default.cpp
    engine/win/music.cpp
    engine/win/process.cpp
    engine/win/quiet.cpp
    engine/win/render.cpp
    engine/win/session_watch.cpp
    engine/win/sessions.cpp
    engine/win/voice.cpp)
  target_include_directories(ps_win PUBLIC engine ${PS_THIRD_PARTY})
  target_link_libraries(ps_win PUBLIC ps_dsp ole32 oleaut32 uuid mmdevapi avrt propsys shlwapi version advapi32
    bcrypt setupapi newdev urlmon)

  add_library(PitchShiftEngine SHARED engine/api/engine_api.cpp engine/api/engine.rc)
  target_compile_definitions(PitchShiftEngine PRIVATE PS_ENGINE_BUILD)
  target_link_libraries(PitchShiftEngine PRIVATE ps_win)

  add_executable(PitchShiftTool
    tool/diag.cpp
    tool/e2e.cpp
    tool/main.cpp
    tool/probe.cpp
    tool/record.cpp
    tool/render.cpp
    tool/setup.cpp
    tool/tonegen.cpp
    tool/tool.rc)
  target_include_directories(PitchShiftTool PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(PitchShiftTool PRIVATE ps_win)

  # Put everything in one folder (build/out/Release) so it's easy to find and pack.
  set_target_properties(PitchShiftEngine PitchShiftTool dsp_tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/out)
endif()

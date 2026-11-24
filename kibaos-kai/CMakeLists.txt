cmake_minimum_required(VERSION 3.18)
project(kibaos-kai LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# kibavoiced: the headless assistant daemon the KibaDE shell talks to over
# org.kibaos.Kiba1. Qt Core + DBus only: no Widgets, no display.
find_package(Qt6 REQUIRED COMPONENTS Core DBus)
add_executable(kibavoiced src/kibavoiced.cpp src/audio.cpp src/backend.cpp)
target_link_libraries(kibavoiced PRIVATE Qt6::Core Qt6::DBus)
install(TARGETS kibavoiced RUNTIME DESTINATION bin)

# kibavoice: kAI's engine CLI (llama.cpp + whisper-cli + Piper). kibavoiced runs
# it as a child process. Off for daemon-only builds and tests.
option(KIBAVOICE_ENGINE "Build the kibavoice engine CLI" ON)
if(KIBAVOICE_ENGINE)
  set(LLAMA_CPP_TAG   "v1.0.0" CACHE STRING "llama.cpp git tag")
  set(WHISPER_CPP_TAG "v1.9.5" CACHE STRING "whisper.cpp git tag")
  include(FetchContent)
  include(ExternalProject)
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(llama GIT_REPOSITORY https://github.com/ggml-org/llama.cpp
    GIT_TAG ${LLAMA_CPP_TAG} GIT_SHALLOW TRUE)
  FetchContent_MakeAvailable(llama)
  add_executable(kibavoice src/kibavoice.cpp)
  target_link_libraries(kibavoice PRIVATE llama)
  ExternalProject_Add(whisper_cpp
    GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp
    GIT_TAG ${WHISPER_CPP_TAG} GIT_SHALLOW TRUE
    CMAKE_ARGS -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
               -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target whisper-cli --config Release
    INSTALL_COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/bin/whisper-cli ${CMAKE_BINARY_DIR}/whisper-cli)
  add_dependencies(kibavoice whisper_cpp)
  install(TARGETS kibavoice RUNTIME DESTINATION bin)
  install(PROGRAMS ${CMAKE_BINARY_DIR}/whisper-cli DESTINATION libexec/kibavoice)
endif()

install(FILES org.kibaos.Kiba1.xml DESTINATION share/dbus-1/interfaces)
install(FILES data/org.kibaos.Kiba.service DESTINATION share/dbus-1/services)
install(FILES data/kibavoiced.service DESTINATION lib/systemd/user)

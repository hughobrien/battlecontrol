cmake_minimum_required(VERSION 3.20)

find_package(SDL2 REQUIRED)
find_package(SDL2_ttf REQUIRED)
find_package(SDL2_image REQUIRED)

add_executable(ra-setup
    ra-installer.cpp
)

target_compile_features(ra-setup PRIVATE cxx_std_17)

target_include_directories(ra-setup PRIVATE
    ${SDL2_INCLUDE_DIRS}
    ${SDL2_TTF_INCLUDE_DIRS}
    ${SDL2_IMAGE_INCLUDE_DIRS}
)

target_link_libraries(ra-setup PRIVATE
    ${SDL2_LIBRARIES}
    SDL2_ttf
    SDL2_image
)

install(TARGETS ra-setup DESTINATION bin)

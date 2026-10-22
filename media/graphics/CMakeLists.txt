file(GLOB KIBA_SPRITES "${CMAKE_CURRENT_SOURCE_DIR}/kiba/*.png")
foreach(item ${KIBA_SPRITES})
    add_cd_file(FILE "${item}" DESTINATION reactos/media/graphics/kiba FOR all)
endforeach()

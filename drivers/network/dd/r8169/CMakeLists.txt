add_definitions(
    -DNDIS630_MINIPORT
    -DNDIS_MINIPORT_DRIVER)

list(APPEND SOURCE
    r8169.c
    r8169.h
    r8169hw.h)

add_library(r8169 MODULE ${SOURCE} r8169.rc)
add_pch(r8169 r8169.h SOURCE)
set_module_type(r8169 kernelmodedriver)

if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
    target_compile_options(r8169 PRIVATE
        -Wno-unused-function
        -Wno-unused-variable)
endif()

add_importlibs(r8169 ndis ntoskrnl hal)
add_cd_file(TARGET r8169 DESTINATION reactos/system32/drivers FOR all)
add_driver_inf(r8169 netr8169.inf)

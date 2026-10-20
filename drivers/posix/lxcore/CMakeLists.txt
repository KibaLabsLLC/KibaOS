list(APPEND SOURCE
    main.c
    elf.c
    syscalls.c
    vfs.c)

add_library(lxcore MODULE ${SOURCE})
set_module_type(lxcore kernelmodedriver)
add_importlibs(lxcore ntoskrnl hal)
add_pch(lxcore lxcore.h SOURCE)
add_cd_file(TARGET lxcore DESTINATION reactos/system32/drivers FOR all)

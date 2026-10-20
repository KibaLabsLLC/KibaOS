
add_driver(lxcore lxcore.sys
    main.c
    elf.c
    syscalls.c
    vfs.c)

add_pch(lxcore lxcore.h)
add_cd_file(TARGET lxcore DESTINATION reactos/system32/drivers FOR all)

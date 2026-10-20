
add_executable(lxrun lxrun.c)
set_module_type(lxrun win32cui)
add_importlibs(lxrun msvcrt kernel32)
add_cd_file(TARGET lxrun DESTINATION reactos/system32 FOR all)

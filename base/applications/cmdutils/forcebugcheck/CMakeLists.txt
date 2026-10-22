add_executable(forcebugcheck forcebugcheck.c)
set_module_type(forcebugcheck win32c)
add_importlibs(forcebugcheck msvcrt kernel32 ntdll)
add_cd_file(TARGET forcebugcheck DESTINATION reactos/system32 FOR all)

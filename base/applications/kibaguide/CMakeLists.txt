add_executable(kibaguide kibaguide.cpp kibaguide.rc)
set_module_type(kibaguide win32gui UNICODE)
add_importlibs(kibaguide gdi32 user32 shell32 comctl32 msvcrt kernel32 ntdll)
add_cd_file(TARGET kibaguide DESTINATION reactos/system32 FOR all)

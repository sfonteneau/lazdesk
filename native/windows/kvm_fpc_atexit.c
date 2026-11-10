/* MinGW-w64 C++ runtime adapter for a Free Pascal Windows EXE.
 *
 * The program's entry point belongs to FPC, not MinGW's crtexe.o.
 * MinGW normally supplies atexit() in crtexe.c, so static libstdc++
 * otherwise has an unresolved reference.  Reproduce only MinGW's
 * forwarding behavior without linking its startup/TLS objects.
 *
 * Never replace this with a no-op: C++ destructors must be registered.
 */
#if !defined(_WIN32)
#error This adapter is only for MinGW-w64 Windows builds.
#endif

#include <stdlib.h>

/* This entry point is provided by the selected MinGW CRT import archive,
 * which is already staged in libkvm_wincrt.a.  Both i386 and x64 use cdecl.
 */
extern int __cdecl _crt_atexit(void (__cdecl *callback)(void));

int __cdecl atexit(void (__cdecl *callback)(void)) {
    return _crt_atexit(callback);
}

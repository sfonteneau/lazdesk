# Native build archives

`build/build_standalone.py` creates a subdirectory here for each CPU/OS target.
It contains `.a` archives, intermediate `.o` objects, `.inc` linkage files,
and the build manifest. These files do **not** belong on the target machine.
Never reuse an archive built for a different OS, CPU, or compiler.

No precompiled third-party libraries are included with these sources.
Archives are built or copied on the build machine from the project's native
sources and the selected TurboJPEG library.
A `.dll.a` import archive is **not** a self-contained static library.

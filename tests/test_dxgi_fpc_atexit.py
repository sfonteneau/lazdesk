#!/usr/bin/env python3
"""C/COFF and builder regression for the FPC+MinGW static DXGI atexit bridge.

This does NOT execute LazDesk or claim to validate a Windows Lazarus build.
"""
from pathlib import Path
import importlib.util
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lazdesk_atexit_builder', ROOT/'build/build_standalone.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class DxgiFpcAtexit(unittest.TestCase):
    def test_builder_stages_real_bridge_with_correct_link_order(self):
        source = (ROOT/'build/build_standalone.py').read_text(encoding='utf-8')
        self.assertIn("stage/'libkvm_fpc_atexit.a'", source)
        self.assertIn("ROOT/'native/windows/kvm_fpc_atexit.c'", source)
        self.assertIn("assert_archive(stage/'libkvm_fpc_atexit.a', nm, ['atexit'])", source)
        self.assertRegex(source, r"links=\['\{\$LINKLIB '\+name\+'\}', '\{\$LINKLIB kvm_fpc_atexit\}',\s*'\{\$LINKLIB kvm_wincrt\}'\]")
        self.assertNotIn('libkvm_mingw32.a\'\'', source)

    def test_shim_registers_in_real_windows_crt(self):
        source = (ROOT/'native/windows/kvm_fpc_atexit.c').read_text(encoding='utf-8')
        self.assertIn('return _crt_atexit(callback);', source)
        self.assertNotRegex(source, r'return\s+0\s*;')
        self.assertRegex(source, r'int\s+__cdecl\s+atexit\(')

    def test_pascal_smoke_links_dxgi_before_lazarus(self):
        source = (ROOT/'tests/test_standalone_link.lpr').read_text(encoding='utf-8')
        self.assertIn('{$I kvm_build.inc}', source)
        self.assertIn('{$IFDEF KVM_STATIC_DXGI}kvm_dxgi_static,{$ENDIF}', source)
        self.assertIn('Require(KvmDxgiAbi=3', source)
        builder = (ROOT/'build/build_standalone.py').read_text(encoding='utf-8')
        self.assertLess(builder.index("ROOT/'tests/test_standalone_link.lpr'"),
                        builder.index("if mormot_package is not None:"))

    @unittest.skipUnless(all(shutil.which(c) for c in ('clang','llvm-ar','lld-link')),
                         'clang/llvm-ar/lld-link required for cross COFF test')
    def test_windows_coff_archive_links_on_both_architectures(self):
        for target, arch in (('i686-w64-windows-gnu','x86'), ('x86_64-w64-windows-gnu','x64')):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory(prefix='kvm-atexit-coff-') as td:
                root = Path(td)
                headers = root/'headers'; headers.mkdir()
                (headers/'stdlib.h').write_text(
                    '#define __cdecl __attribute__((cdecl))\n'
                    'int __cdecl atexit(void (__cdecl *)(void));\n',encoding='ascii')
                bridge = root/'fpc_atexit.obj'
                subprocess.run(['clang','-target',target,'-std=c11','-nostdinc',
                                '-I',str(headers),'-c',str(ROOT/'native/windows/kvm_fpc_atexit.c'),
                                '-o',str(bridge)],check=True,capture_output=True)
                stubs = root/'crt_stub.c'
                stubs.write_text(
                    '#define __cdecl __attribute__((cdecl))\n'
                    'static int registrations;\n'
                    'int __cdecl _crt_atexit(void (__cdecl *cb)(void)) {\n'
                    '  if (!cb) return -1; ++registrations; return 0; }\n'
                    'int __cdecl atexit(void (__cdecl *cb)(void));\n'
                    'static void cleanup(void) {}\n'
                    'int lazdesk_probe(void) { return atexit(cleanup) || registrations!=1; }\n',
                    encoding='ascii')
                stub = root/'crt_stub.obj'
                subprocess.run(['clang','-target',target,'-std=c11','-nostdinc',
                                '-c',str(stubs),'-o',str(stub)],check=True,capture_output=True)
                lib = root/'libkvm_fpc_atexit.a'
                subprocess.run(['llvm-ar','rcs',str(lib),str(bridge)],check=True,capture_output=True)
                exe=root/'test.exe'
                subprocess.run(['lld-link','/entry:lazdesk_probe', '/subsystem:console',
                                '/nodefaultlib', '/machine:'+arch, '/out:'+str(exe),
                                str(stub),str(lib)],check=True,capture_output=True)
                self.assertEqual(exe.read_bytes()[:2],b'MZ')


if __name__ == '__main__':
    unittest.main(verbosity=2)

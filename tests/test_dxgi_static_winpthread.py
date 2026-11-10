#!/usr/bin/env python3
"""Regression du build C++/DXGI autonome, sans execution sur Windows.

Controle les garanties de liaison WinPthreads, et verifie le mecanisme
GNU ar de regroupement avec des objets reels du compilateur hote.
"""
from pathlib import Path
import importlib.util
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lazdesk_static_builder', ROOT/'build/build_standalone.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class DxgiStaticWinpthread(unittest.TestCase):
    def test_builder_stages_real_static_winpthread_for_dxgi(self):
        source = (ROOT/'build/build_standalone.py').read_text(encoding='utf-8')
        self.assertIn("if args.with_dxgi:\n            # The POSIX-thread", source)
        self.assertIn("'-print-file-name=libwinpthread.a'", source)
        self.assertIn("stage_runtime(cc, stage, 'winpthread', 'kvm_winpthread')", source)
        self.assertIn("check_windows_archive(pthread_archive, objdump, cpu)", source)
        self.assertIn("assert_archive(pthread_archive, nm, ['pthread_create', 'pthread_join'])", source)
        self.assertIn('crt_archives.append(pthread_archive)', source)
        self.assertIn("*runtime_archives,stage/'libkvm_wincrt.a'", source)
        self.assertIn("audit_binary(stage/'probe_dxgi.exe'", source)
        # The security guard must continue rejecting this runtime DLL.
        audit = (ROOT/'tools/audit_standalone.py').read_text(encoding='utf-8')
        self.assertNotIn("'libwinpthread-1.dll'", audit.split('WIN_SYSTEM = ')[-1].split('def invoke')[0])

    @unittest.skipUnless(shutil.which('gcc') and shutil.which('ar') and shutil.which('nm'),
                         'gcc/ar/nm are needed to test GNU archive resolution')
    def test_static_thread_symbols_survive_merged_archive(self):
        with tempfile.TemporaryDirectory(prefix='lazdesk-winpthread-test-') as tmp:
            root = Path(tmp)
            sources = {
                'bridge.c': 'extern int cpp(void); int bridge(void){return cpp();}\n',
                'cpp.c': 'extern int pthread_create(void); extern int pthread_join(void); '
                         'int cpp(void){return pthread_create()+pthread_join();}\n',
                'pthread.c': 'extern int gcc_helper(void); int pthread_create(void){return gcc_helper();} '
                             'int pthread_join(void){return 2;}\n',
                'gcc.c': 'int gcc_helper(void){return 1;}\n',
                'main.c': 'extern int bridge(void); int main(void){return bridge()!=3;}\n',
            }
            for name, contents in sources.items():
                source = root/name
                source.write_text(contents, encoding='utf-8')
                subprocess.run(['gcc','-c',str(source),'-o',str(root/(name+'.o'))], check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for lib, obj in [('kvm_dxgi','bridge'),('kvm_stdcpp','cpp'),
                             ('kvm_winpthread','pthread'),('kvm_gcc','gcc')]:
                subprocess.run(['ar','rcs',str(root/('lib'+lib+'.a')),str(root/(obj+'.c.o'))],
                               check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            b.assert_archive(root/'libkvm_winpthread.a','nm',['pthread_create','pthread_join'])
            b.merge_crt_archives('ar',root/'libkvm_wincrt.a',
                                 [root/'libkvm_winpthread.a', root/'libkvm_gcc.a'])
            exe = root/'test'
            subprocess.run(['gcc',str(root/'main.c.o'),str(root/'libkvm_dxgi.a'),
                            '-Wl,--start-group',str(root/'libkvm_stdcpp.a'),
                            str(root/'libkvm_wincrt.a'),'-Wl,--end-group', '-o',str(exe)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run([str(exe)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)


if __name__ == '__main__':
    unittest.main(verbosity=2)

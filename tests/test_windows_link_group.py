"""Regression: genuine ar archives, no ld GROUP script in Windows FPC build.

Tests native archive merging on Linux; does not claim to compile Windows FPC.
"""
from pathlib import Path
import importlib.util
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('lazdesk_builder', ROOT/'build/build_standalone.py')
b=importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

class TestLinkGroup(unittest.TestCase):
    def test_rejects_missing_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(b.BuildError):
                b.merge_crt_archives('ar', Path(tmp)/'libkvm_wincrt.a',[Path(tmp)/'missing.a'])

    @unittest.skipUnless(shutil.which('gcc') and shutil.which('ar'),
                         'GCC and GNU ar required')
    def test_real_gnu_ld_rescans_cyclic_libraries(self):
        with tempfile.TemporaryDirectory(prefix='kvm group regression ') as tmp:
            root=Path(tmp)
            contents={
                'a1.c':'extern int b(void); int a(void){ return b()+1; }\n',
                'a2.c':'int a_helper(void){ return 4; }\n',
                'b1.c':'extern int a_helper(void); int b(void){ return a_helper()+2; }\n',
                'main.c':'extern int a(void); int main(void){return a()!=7;}\n',
            }
            for name,text in contents.items():
                (root/name).write_text(text)
                subprocess.run(['gcc','-c',str(root/name),'-o',str(root/(name+'.o'))],check=True,
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            a=root/'liba.a'; bb=root/'libb.a'
            subprocess.run(['ar','rcs',str(a),str(root/'a1.c.o'),str(root/'a2.c.o')],check=True)
            subprocess.run(['ar','rcs',str(bb),str(root/'b1.c.o')],check=True)
            aa=root/'libkvm_mingwex.a'; aaa=root/'libkvm_gcc.a'
            shutil.copy2(a,aa); shutil.copy2(bb,aaa)
            archive=root/'libkvm_wincrt.a'
            archive.write_text('GROUP ( obsolete )\n')
            b.merge_crt_archives('ar',archive,[aa,aaa])
            self.assertEqual(archive.read_bytes()[:8], b'!<arch>\n')
            self.assertNotIn(b'GROUP (',archive.read_bytes())
            members=subprocess.check_output(['ar','t',str(archive)],text=True).splitlines()
            self.assertEqual(len(members),3)
            exe=root/'probe'
            subprocess.run(['gcc',str(root/'main.c.o'),'-L',str(root),'-lkvm_wincrt','-o',str(exe)],
                           check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            subprocess.run([str(exe)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)

    @unittest.skipUnless(shutil.which('clang') and shutil.which('llvm-ar') and
                         shutil.which('lld-link') and shutil.which('ar'),
                         'Clang/LLVM and GNU ar required')
    def test_windows_i386_coff_archive_merge_and_pe_link(self):
        """Actual Windows COFF inputs; no FPC or Windows execution implied."""
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name, src in {
                'foo': 'int b(void); int foo(void){return b();}\n',
                'bar': 'int b(void){return 123;}\n',
                'entry': 'int foo(void); int lazdesk_probe(void){return foo()!=123;}\n',
            }.items():
                (root/(name+'.c')).write_text(src)
                subprocess.run(['clang','-target','i686-w64-windows-gnu','-c',
                                root/(name+'.c'),'-o',root/(name+'.o')],check=True,
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            aa=root/'libkvm_gcc.a'; bb=root/'libkvm_mingwex.a'
            subprocess.run(['llvm-ar','rcs',aa,root/'foo.o'],check=True)
            subprocess.run(['llvm-ar','rcs',bb,root/'bar.o'],check=True)
            merged=root/'libkvm_wincrt.a'
            b.merge_crt_archives('ar',merged,[aa,bb])
            self.assertEqual(merged.read_bytes()[:8],b'!<arch>\n')
            exe=root/'probe.exe'
            subprocess.run(['lld-link','/entry:lazdesk_probe','/subsystem:console',
                            '/nodefaultlib','/machine:x86','/out:'+str(exe),
                            root/'entry.o',merged],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            self.assertEqual(exe.read_bytes()[:2],b'MZ')

if __name__=='__main__':
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Target selection regression tests, NOT a Windows LazDesk build.

The integration test mocks compiler output. The native fixture test really
creates tiny COFF/PE files with Clang/LLD when available; it never compiles or
runs LazDesk, Lazarus, TurboJPEG or DXGI.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('arch_build', ROOT/'build/build_standalone.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


def exe_fixture(path, cpu):
    raw = bytearray(134)
    raw[:2] = b'MZ'
    struct.pack_into('<I', raw, 60, 128)
    raw[128:132] = b'PE\0\0'
    struct.pack_into('<H', raw, 132, 0x014c if cpu == 'i386' else 0x8664)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)


def dummy_tool(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\nexit 0\n')
    path.chmod(0o755)
    return str(path)


class Targets(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def host(self, system, machine, arch):
        with patch.object(b.platform, 'system', return_value=system), \
             patch.object(b.platform, 'machine', return_value=machine):
            return b.host_target(arch)

    def test_x86_selected_on_windows_x64(self):
        self.assertEqual(self.host('Windows', 'AMD64', 'x86'), ('i386', 'win32'))

    def test_x64_selected(self):
        self.assertEqual(self.host('Windows', 'AMD64', 'x64'), ('x86_64', 'win64'))

    def test_native_x86(self):
        self.assertEqual(self.host('Windows', 'x86', 'native'), ('i386', 'win32'))

    def test_native_x64(self):
        self.assertEqual(self.host('Windows', 'AMD64', 'native'), ('x86_64', 'win64'))

    def test_wow64_python_not_used_as_target(self):
        with patch.dict(os.environ, {'PROCESSOR_ARCHITEW6432':'AMD64'}):
            self.assertEqual(self.host('Windows', 'x86', 'x64'), ('x86_64', 'win64'))

    def test_x64_rejected_on_32bit_windows(self):
        with self.assertRaises(b.BuildError):
            self.host('Windows', 'x86', 'x64')

    def test_other_system_native_preserved(self):
        self.assertEqual(self.host('Linux', 'x86_64', 'native'), ('x86_64', 'linux'))
        self.assertEqual(self.host('Darwin', 'arm64', 'native'), ('aarch64', 'darwin'))

    def test_cross_os_not_silently_added(self):
        for system, machine, arch in [('Linux','x86_64','x86'), ('Darwin','arm64','x64'),
                                      ('Windows','ARM64','x86')]:
            with self.subTest(system=system), self.assertRaises(b.BuildError):
                self.host(system, machine, arch)

    def test_unknown_arch_rejected(self):
        with self.assertRaises(b.BuildError):
            self.host('Windows', 'AMD64', 'x128')

    def test_fpc_target_switches_used_for_queries(self):
        for cpu, system in [('i386','win32'), ('x86_64','win64')]:
            with patch.object(b, 'run', side_effect=[cpu, system]) as run:
                b.check_fpc_target('fpc.exe', cpu, system)
                self.assertEqual(run.call_args_list[0].args[0],
                                 ['fpc.exe','-P'+cpu,'-T'+system,'-iTP'])
                self.assertEqual(run.call_args_list[1].args[0][-1], '-iTO')

    def test_fpc_cannot_silently_ignore_requested_cpu(self):
        with patch.object(b, 'run', side_effect=['i386','win32']), self.assertRaises(b.BuildError):
            b.check_fpc_target('fpc.exe', 'x86_64', 'win64')

    def test_fpc_missing_target_is_explained(self):
        with patch.object(b, 'run', side_effect=b.BuildError('ppcrossx64 absent')):
            with self.assertRaisesRegex(b.BuildError, 'Install the compiler'):
                b.check_fpc_target('fpc.exe', 'x86_64', 'win64')

    def test_c_targets_accept_both(self):
        for cpu, system, triple in [('i386','win32','i686-w64-mingw32'),
                                     ('i386','win32','i386-pc-mingw32'),
                                     ('x86_64','win64','x86_64-w64-mingw32')]:
            with patch.object(b, 'run', return_value=triple):
                b.check_c_target('gcc',cpu,system)

    def test_c_target_mismatch_is_not_overridden(self):
        for cpu, system, triple in [('i386','win32','x86_64-w64-mingw32'),
                                     ('x86_64','win64','i686-w64-mingw32'),
                                     ('i386','win32','i686-pc-linux-gnu'),
                                     ('x86_64','win64','x86_64-pc-windows-msvc')]:
            with self.subTest(triple=triple), patch.object(b, 'run', return_value=triple), \
                 self.assertRaises(b.BuildError):
                b.check_c_target('gcc',cpu,system)

    def test_x86_fpc_macro_is_cpu386(self):
        text=b.feature_include('i386','win32',[])
        self.assertIn('IFNDEF CPU386',text)
        self.assertIn('IFNDEF WIN32',text)
        self.assertNotIn('CPUI386',text)

    def test_x64_fpc_macro_preserved(self):
        text=b.feature_include('x86_64','win64',['KVM_STATIC_DXGI'])
        self.assertIn('IFNDEF CPUX86_64',text)
        self.assertIn('IFNDEF WIN64',text)
        self.assertIn('DEFINE KVM_STATIC_DXGI',text)

    def test_sdk_folder_priority_and_spaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk=Path(tmp)/'MinGW 32'/ 'bin'
            gcc=dummy_tool(sdk/'gcc.exe')
            ar=dummy_tool(sdk/'ar.exe')
            self.assertEqual(b.select_c_tool('gcc',None,sdk,cpu='i386'),gcc)
            self.assertEqual(b.select_c_tool('ar',None,sdk,gcc,cpu='i386'),ar)

    def test_prefixed_sdk_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk=Path(tmp)
            cc=dummy_tool(sdk/'i686-w64-mingw32-gcc.exe')
            ar=dummy_tool(sdk/'i686-w64-mingw32-ar.exe')
            self.assertEqual(b.select_c_tool('gcc',None,sdk,cpu='i386'),cc)
            self.assertEqual(b.select_c_tool('ar',None,sdk,cc,cpu='i386'),ar)

    def test_prefixed_gcc_on_path_matches_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk=Path(tmp)
            wanted=dummy_tool(sdk/'i686-w64-mingw32-gcc')
            dummy_tool(sdk/'gcc')
            with patch.dict(os.environ, {'PATH':str(sdk)}):
                self.assertEqual(b.select_c_tool('gcc',None,None,cpu='i386'),wanted)

    def test_incomplete_sdk_does_not_fallback_to_path(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(b.BuildError, 'complete MinGW toolchain'):
            b.select_c_tool('nm',None,Path(tmp),cpu='i386')

    def test_dxgi_sdk_library_dirs_forwarded_to_fpc_and_lazarus(self):
        with tempfile.TemporaryDirectory(prefix='sdk with spaces ') as tmp:
            root=Path(tmp)
            libdir=root/'mingw32'/'lib'
            libdir.mkdir(parents=True)
            required=('d3d11','dxgi','dxguid','uuid','user32','gdi32','kernel32','advapi32')
            for name in required:
                (libdir/('lib'+name+'.a')).write_bytes(b'!<arch>\n')
            def fake_run(args,**kwargs):
                return str(libdir/str(args[-1]).partition('=')[2])
            with patch.object(b,'run',side_effect=fake_run):
                dirs=b.windows_sdk_library_directories('C:/msys64/mingw32/bin/gcc.exe')
            self.assertEqual(dirs,[str(libdir.resolve())])
            projectroot=root/'project'
            for role,app in [('server','LazDeskServer'),('client','LazDeskClient')]:
                (projectroot/role).mkdir(parents=True)
                shutil.copy2(ROOT/role/(app+'.lpi'),projectroot/role)
            with patch.object(b,'ROOT',projectroot):
                projects=b.make_projects('i386-win32',dirs,'win32')
            for project in projects:
                self.assertIn(str(libdir.resolve()), ET.parse(project).find('.//SearchPaths/Libraries').get('Value'))
            self.assertIn('-Fl'+str(libdir.resolve()),['-Fl'+p for p in dirs])

    def test_dxgi_sdk_libraries_missing_give_actionable_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            libdir=Path(tmp)
            (libdir/'libuser32.a').write_bytes(b'!<arch>\n')
            def fake_run(args, **kwargs):
                return str(libdir/str(args[-1]).partition('=')[2])
            with patch.object(b,'run',side_effect=fake_run), \
                 self.assertRaisesRegex(b.BuildError,'libd3d11.a'):
                b.windows_sdk_library_directories('gcc')

    def test_linker_flags_and_lpi_quoting(self):
        flags=b.windows_linker_flags('/MinGW 32/bin/gcc.exe','/MinGW 32/bin/ld.exe')
        self.assertEqual(flags,['-Xe','-FD/MinGW 32/bin','-XP'])
        self.assertIn('"-FD/MinGW 32/bin"', b.option_text(flags))
        with self.assertRaises(b.BuildError):
            b.option_text(['-FDpath"invalid'])

    def test_unprefixed_ld_with_prefixed_msys2_gcc(self):
        """Real configuration from the user's MSYS2 MINGW32 diagnostic."""
        cc='/MinGW32/bin/i686-w64-mingw32-gcc.exe'
        ld='/MinGW32/bin/ld.exe'
        self.assertEqual(b.windows_linker_flags(cc,ld),
                         ['-Xe','-FD/MinGW32/bin','-XP'])
        self.assertEqual(b.windows_linker_flags(cc,'/MinGW32/bin/i686-w64-mingw32-ld.exe'),
                         ['-Xe','-FD/MinGW32/bin','-XPi686-w64-mingw32-'])
        with self.assertRaises(b.BuildError):
            b.windows_linker_flags(cc,'/MinGW32/bin/link.exe')

    def test_linker_default_format_is_verified_not_its_name(self):
        for cpu,fmt in [('i386','pei-i386'),('x86_64','pei-x86-64')]:
            with patch.object(b,'run',return_value=f'GNU ld\nOUTPUT_FORMAT("{fmt}")') as mock:
                b.check_windows_linker('ld.exe',cpu)
                mock.assert_called_once_with(['ld.exe','--verbose'],capture=True)
        for cpu,fmt in [('i386','pei-x86-64'),('x86_64','pei-i386'),
                        ('i386','elf64-x86-64'),('i386','')]:
            with patch.object(b,'run',return_value='OUTPUT_FORMAT("'+fmt+'")'):
                with self.assertRaisesRegex(b.BuildError,'Linker incompatible'):
                    b.check_windows_linker('ld.exe',cpu)

    def test_archive_formats(self):
        for cpu,fmt in [('i386','pe-i386'), ('x86_64','pe-x86-64')]:
            with patch.object(b,'run',return_value='a.o: file format '+fmt):
                b.check_windows_archive(Path('jpeg.a'),'objdump',cpu)
                with self.assertRaises(b.BuildError):
                    b.check_windows_archive(Path('jpeg.a'),'objdump', 'i386' if cpu=='x86_64' else 'x86_64')
        for text in ['', 'file format elf64-x86-64', 'file format pe-i386\nfile format pe-x86-64']:
            with patch.object(b,'run',return_value=text), self.assertRaises(b.BuildError):
                b.check_windows_archive(Path('jpeg.a'),'objdump','i386')

    def test_pe_headers_reject_wrong_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'probe.exe'
            for cpu in ['i386','x86_64']:
                exe_fixture(p,cpu)
                b.check_pe_target(p,cpu)
                with self.assertRaises(b.BuildError):
                    b.check_pe_target(p, 'i386' if cpu=='x86_64' else 'x86_64')
            p.write_bytes(b'MZ'+bytes(100))
            with self.assertRaises(b.BuildError): b.check_pe_target(p,'i386')

    def test_projects_do_not_overwrite_other_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for role,app in [('server','LazDeskServer'),('client','LazDeskClient')]:
                (root/role).mkdir()
                shutil.copy2(ROOT/role/(app+'.lpi'), root/role)
            with patch.object(b,'ROOT',root):
                paths=[]
                for cpu,system in [('i386','win32'),('x86_64','win64')]:
                    projects=b.make_projects(cpu+'-'+system,[],system,fpc='/FPC dir/fpc.exe',
                                             linker_flags=['-Xe','-FD/MinGW dir/bin','-XP'])
                    paths.extend(projects)
                    for p in projects:
                        tree=ET.parse(p)
                        self.assertEqual(tree.find('.//CodeGeneration/TargetCPU').get('Value'),cpu)
                        self.assertEqual(tree.find('.//CodeGeneration/TargetOS').get('Value'),system)
                        self.assertIn(cpu+'-'+system,tree.find('.//UnitOutputDirectory').get('Value'))
                        self.assertTrue(tree.find('.//Target/Filename').get('Value').endswith('.exe'))
                        self.assertIn('"-FD/MinGW dir/bin"',tree.find('.//CustomOptions').get('Value'))
                self.assertEqual(len(set(paths)),4)
                self.assertTrue(all(p.is_file() for p in paths))

    def test_full_build_orchestration_mocked(self):
        """Assert actual main() commands/paths with simulated compiler replies."""
        with tempfile.TemporaryDirectory(prefix='lazdesk arch ') as tmp:
            root=Path(tmp)
            for role,app in [('server','LazDeskServer'),('client','LazDeskClient')]:
                (root/role).mkdir()
                shutil.copy2(ROOT/role/(app+'.lpi'), root/role)
            # The standalone client now distributes editable language catalogs.
            shutil.copytree(ROOT/'client/languages',root/'client/languages')
            sdk=root/'MinGW SDK'/'bin'
            for name in ['gcc','ar','nm','objdump','ld']:
                dummy_tool(sdk/(name+'.exe'))
            fpc=dummy_tool(root/'FPC'/'fpc.exe')
            laz=dummy_tool(root/'Lazarus'/'lazbuild.exe')
            jpeg=root/'libturbojpeg.a'; jpeg.write_bytes(b'!<arch>\n')
            for lib in ['mingw32','mingwex','gcc','gcc_eh','msvcrt','kernel32']:
                (root/('lib'+lib+'.a')).write_bytes(b'!<arch>\n')
            for arch,cpu,system in [('x86','i386','win32'),('x64','x86_64','win64')]:
                calls=[]
                runtime_probes=[]
                def fake_run(argv,**kwargs):
                    args=[str(x) for x in argv]; calls.append(args)
                    if kwargs.get('clean_windows_runtime'):
                        runtime_probes.append((args, kwargs.get('cwd')))
                    if '-dumpmachine' in args:
                        return ('i686' if cpu=='i386' else 'x86_64')+'-w64-mingw32'
                    if '--verbose' in args and args[0].endswith('ld.exe'):
                        return 'GNU ld\nOUTPUT_FORMAT("'+('pei-i386' if cpu=='i386' else 'pei-x86-64')+'")'
                    if '-iTP' in args: return cpu
                    if '-iTO' in args: return system
                    if args[0].endswith('nm.exe'):
                        return '\n'.join('000 T '+('_' if cpu=='i386' else '')+n for n in [
                            'tjInitCompress','tjInitDecompress','tjCompress2','tjDecompress2',
                            'tjDecompressHeader3','tjBufSize','tjDestroy','tjGetErrorStr2'])
                    if args[0].endswith('objdump.exe'):
                        return 'jpeg.o: file format '+('pe-i386' if cpu=='i386' else 'pe-x86-64')
                    for arg in args:
                        if arg.startswith('-print-file-name='):
                            return str(root/arg.split('=',1)[1])
                    if '-o' in args: exe_fixture(Path(args[args.index('-o')+1]),cpu)
                    for arg in args:
                        if arg.startswith('-o') and len(arg)>2: exe_fixture(Path(arg[2:]),cpu)
                    if args[0]==laz:
                        project=Path(args[-1]); tree=ET.parse(project)
                        exe_fixture((project.parent/tree.find('.//Target/Filename').get('Value')).resolve(),cpu)
                    return ''
                def fake_merge(ar, path, archives):
                    path.parent.mkdir(parents=True,exist_ok=True)
                    path.write_bytes(b'!<arch>\n' + b''.join(p.name.encode('ascii') for p in archives))
                    self.assertFalse(any(p.name=='libkvm_mingw32.a' for p in archives))
                with patch.object(b,'merge_crt_archives',side_effect=fake_merge), \
                     patch.object(b,'ROOT',root), patch.object(b.platform,'system',return_value='Windows'), \
                     patch.object(b.platform,'machine',return_value='AMD64'), patch.object(b,'run',side_effect=fake_run), \
                     patch.dict(os.environ, {'CC':'/unrelated/Strawberry/gcc.exe'}):
                    result=b.main(['--arch',arch,'--toolchain-bin',str(sdk),'--fpc',fpc,'--lazbuild',laz,
                                   '--turbojpeg-archive',str(jpeg)])
                self.assertEqual(result,0)
                # The C and Pascal probes run without the developer MinGW PATH.
                self.assertEqual(len(runtime_probes),2)
                self.assertTrue(all(cwd is not None for _,cwd in runtime_probes))
                names=[a for cmd in calls for a in cmd if a.startswith('-print-file-name=')]
                self.assertEqual('-print-file-name=libgcc_eh.a' in names, cpu=='i386')
                pascal=[c for c in calls if c[0]==fpc and '-B' in c]
                self.assertEqual(len(pascal),1)
                self.assertIn('-P'+cpu,pascal[0]); self.assertIn('-T'+system,pascal[0])
                self.assertIn('-XP',pascal[0])
                laz_commands=[c for c in calls if c[0]==laz]
                self.assertEqual(len(laz_commands),2)
                for cmd in laz_commands:
                    self.assertIn('--cpu='+cpu,cmd); self.assertIn('--os='+system,cmd)
                self.assertTrue((root/'dist'/ (cpu+'-'+system)/'LazDeskServer.exe').is_file())
                staging=root/'native/static'/(cpu+'-'+system)
                links=(staging/'kvm_turbojpeg_link.inc').read_text()
                self.assertEqual(links.strip(), '{$LINKLIB kvm_wincrt}')
                archive=(staging/'libkvm_wincrt.a').read_bytes()
                self.assertTrue(archive.startswith(b'!<arch>\n'))
                self.assertNotIn(b'GROUP (',archive)
                for expected in ['libkvm_mingwex.a','libkvm_gcc.a',
                                 'libkvm_msvcrt.a','libkvm_kernel32.a']:
                    self.assertIn(expected.encode('ascii'),archive)
                self.assertEqual(b'libkvm_gcc_eh.a' in archive, cpu=='i386')
                self.assertNotIn(b'libkvm_mingw32.a',archive)
            self.assertTrue((root/'server/LazDeskServer_Standalone_x86.lpi').is_file())
            self.assertTrue((root/'server/LazDeskServer_Standalone_x64.lpi').is_file())

    def test_real_msys2_layout_prefixed_gcc_unprefixed_ld(self):
        """MSYS2 MINGW32 has i686-prefixed gcc.exe and plain ld.exe."""
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); sdk=root/'msys2'/'mingw32'/'bin'
            for name in ('i686-w64-mingw32-gcc','ar','nm','objdump','ld'):
                dummy_tool(sdk/(name+'.exe'))
            fpc=dummy_tool(root/'fpc.exe')
            queries=[]
            def fake_run(argv, **kwargs):
                args=[str(a) for a in argv]
                queries.append(args)
                if '-dumpmachine' in args:
                    return 'i686-w64-mingw32'
                if '--verbose' in args and args[0].endswith('ld.exe'):
                    return 'GNU ld\nOUTPUT_FORMAT("pei-i386")'
                if '-iTP' in args: return 'i386'
                if '-iTO' in args: return 'win32'
                return ''
            with patch.object(b,'ROOT',root), patch.object(b.platform,'system',return_value='Windows'), \
                 patch.object(b.platform,'machine',return_value='AMD64'), \
                 patch.object(b,'run',side_effect=fake_run):
                self.assertEqual(b.main(['--arch','x86','--toolchain-bin',str(sdk),
                                         '--fpc',fpc,'--check-toolchain']),0)
            self.assertEqual(len(queries),4)
            self.assertTrue(any('--verbose' in args for args in queries))
            cc=str(sdk/'i686-w64-mingw32-gcc.exe')
            ld=str(sdk/'ld.exe')
            self.assertEqual(b.windows_linker_flags(cc,ld),
                             ['-Xe','-FD'+str(sdk),'-XP'])

    def test_check_toolchain_stops_before_native_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); sdk=root/'bin'
            for name in ['gcc','ar','nm','objdump','ld','fpc']:
                dummy_tool(sdk/(name+'.exe'))
            with patch.object(b,'ROOT',root), patch.object(b.platform,'system',return_value='Windows'), \
                 patch.object(b.platform,'machine',return_value='AMD64'), \
                 patch.object(b,'run',side_effect=['i686-w64-mingw32','OUTPUT_FORMAT("pei-i386")','i386','win32']) as run:
                self.assertEqual(b.main(['--arch','x86','--toolchain-bin',str(sdk),
                                         '--fpc',str(sdk/'fpc.exe'),'--check-toolchain']),0)
                self.assertEqual(run.call_count,4)
                self.assertFalse((root/'native').exists())

    def test_cli_contains_arch_choices(self):
        p=subprocess.run([sys.executable,ROOT/'build/build_standalone.py','--help'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0)
        self.assertIn('--arch {native,x86,x64}',p.stdout)
        self.assertIn('--toolchain-bin',p.stdout)
        self.assertIn('--check-toolchain',p.stdout)


class RealCoffFixtures(unittest.TestCase):
    @unittest.skipUnless(all(shutil.which(t) for t in ['clang','llvm-ar','objdump','lld-link','nm']),
                         'Clang/LLVM/binutils unavailable')
    def test_real_coff_and_pe_x86_x64(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            source=root/'fixture.c'
            source.write_text('int lazdesk_probe(void) { return sizeof(void*); }\n')
            for cpu,triple,machine in [('i386','i686-w64-windows-gnu','x86'),
                                        ('x86_64','x86_64-w64-windows-gnu','x64')]:
                obj=root/(cpu+'.o'); lib=root/(cpu+'.a'); exe=root/(cpu+'.exe')
                b.run(['clang','-target',triple,'-O2','-c',source,'-o',obj])
                b.run(['llvm-ar','rcs',lib,obj])
                b.assert_archive(lib,'nm',['lazdesk_probe'])
                b.check_windows_archive(lib,'objdump',cpu)
                with self.assertRaises(b.BuildError):
                    b.check_windows_archive(lib,'objdump','i386' if cpu=='x86_64' else 'x86_64')
                b.run(['lld-link','/entry:lazdesk_probe','/subsystem:console','/nodefaultlib',
                       '/machine:'+machine,'/out:'+str(exe),obj])
                b.check_pe_target(exe,cpu)
                with self.assertRaises(b.BuildError):
                    b.check_pe_target(exe, 'i386' if cpu=='x86_64' else 'x86_64')
                print('REAL COFF/PE fixture checked, NOT executed:',cpu)


if __name__=='__main__':
    unittest.main(verbosity=2)

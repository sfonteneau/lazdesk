#!/usr/bin/env python3
"""Builder/auditor unit tests. Not a Free Pascal compile or GUI test."""
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
b=load('standalone_build',ROOT/'build/build_standalone.py')
a=load('standalone_audit',ROOT/'tools/audit_standalone.py')

class BuildHelpers(unittest.TestCase):
    def test_link_flags(self):
        text,paths=b.system_links(['-L/opt/libs','-lgio-2.0','-lpthread','-pthread','-framework','Foundation'])
        self.assertEqual(paths,['/opt/libs'])
        self.assertEqual(text.count('{$LINKLIB pthread}'),1)
        self.assertIn('{$LINKFRAMEWORK Foundation}',text)
    def test_unknown_linker_flags_fail(self):
        for flags in [['-Wl,--bad-option'],['-F/unknown'],['/path/lib.a'],['-lbad;name']]:
            with self.assertRaises(b.BuildError): b.system_links(flags)
    def test_audit_windows(self):
        self.assertEqual(a.violations('PE',['USER32.dll','msvcrt.dll','MPR.dll','msi.dll', 'KERNEL32.dll',
            'version.dll', 'ole32.dll', 'api-ms-win-core-libraryloader-l1-1-0.dll']),[])
        for name in ['lazdesk_codec.dll','turbojpeg.dll','libstdc++-6.dll',
                     'libgcc_s_dw2-1.dll','libgcc_s_seh-1.dll','libwinpthread-1.dll',
                     'random_vendor.dll']:
            self.assertTrue(a.violations('PE',[name]))
    def test_audit_windows_actual_fpc_imports(self):
        # Dependencies extracted from test_standalone_link.exe built in the Windows VM.
        dlls=['KERNEL32.dll','msvcrt.dll','kernel32.dll','user32.dll',
              'ole32.dll','version.dll','mpr.dll']
        self.assertEqual(a.violations('PE',dlls),[])
        self.assertTrue(a.violations('PE',dlls+['libgcc_s_dw2-1.dll']))
        self.assertTrue(a.violations('PE',dlls+['turbojpeg.dll']))
    def test_audit_windows_actual_lazdesk_server_imports(self):
        # Exact imports from LazDeskServer.exe x86 as reported by objdump -p.
        dlls=['oleaut32.dll','kernel32.dll','user32.dll','ole32.dll',
              'advapi32.dll','gdi32.dll','version.dll','mpr.dll',
              'wininet.dll','KERNEL32.dll','msvcrt.dll','wtsapi32.dll',
              'crypt32.dll','netapi32.dll','secur32.dll','msi.dll','ws2_32.dll']
        self.assertEqual(a.violations('PE',dlls),[])
        # Keep rejecting non-system dependencies.
        for private in ('libgcc_s_dw2-1.dll','libwinpthread-1.dll',
                        'turbojpeg.dll','libstdc++-6.dll','kvm_private.dll'):
            self.assertTrue(a.violations('PE',dlls+[private]),private)
    def test_audit_unix(self):
        self.assertEqual(a.violations('ELF',['libc.so.6','libX11.so.6','libavcodec.so.61']),[])
        for name in ['liblazdesk_session.so','libturbojpeg.so.0','libkvm_codec.so']:
            self.assertTrue(a.violations('ELF',[name]))
    def test_generated_lpi(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for role,app in [('server','LazDeskServer'),('client','LazDeskClient')]:
                (root/role).mkdir()
                shutil.copy(ROOT/role/(app+'.lpi'),root/role)
            prev=b.ROOT
            try:
                b.ROOT=root
                projects=b.make_projects('x86_64-linux',['/usr/lib/test'],'linux')
                for p in projects:
                    tree=ET.parse(p)
                    self.assertEqual(tree.find('.//BuildModes/Item').get('Name'),'Standalone')
                    self.assertIn('standalone',tree.find('.//UnitOutputDirectory').get('Value'))
                    self.assertEqual(tree.find('.//CustomOptions').get('Value'),'-dKVM_STANDALONE')
                    self.assertIn('native/static/x86_64-linux',tree.find('.//Libraries').get('Value'))
            finally: b.ROOT=prev
    def test_no_native_binary_committed(self):
        # Native outputs are made on the target, not taken from a preceding ZIP.
        for role in ['server','client']:
            self.assertFalse(list((ROOT/role).glob('*.so')))
            self.assertFalse(list((ROOT/role).glob('*.dll')))
    def test_cli_help(self):
        p=subprocess.run([sys.executable,ROOT/'build/build_standalone.py','--help'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0)
        self.assertIn('--with-portal',p.stdout)
        self.assertIn('--mormot-dir',p.stdout)
        self.assertNotIn('--fix-mormot-msi',p.stdout)
        self.assertNotIn('fix_mormot_msi_import',p.stdout)
    @unittest.skipUnless(shutil.which('cc') and shutil.which('ar') and shutil.which('nm'),'C toolchain absent')
    def test_static_session_archive_and_symbols(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'libkvm_session.a'
            b.native_archive('cc','ar',out,ROOT/'native/session/kvm_session_linux.c',
                             ['-std=c11','-O2','-fPIC','-Wno-misleading-indentation'])
            b.assert_archive(out,'nm',['lazdesk_session_abi','lazdesk_session_open_ex','lazdesk_session_poll'])
            with self.assertRaises(b.BuildError): b.assert_archive(out,'nm',['tjInitCompress'])
            fake=Path(tmp)/'fake.a'; fake.write_bytes(b'not an ar archive')
            with self.assertRaises(b.BuildError): b.assert_archive(fake,'nm',['anything'])

# This evaluates ONLY the IFDEF/IFNDEF/ELSE/ENDIF used by the bridge wrappers.
# It is deliberately NOT marketed as a Pascal compiler/syntax checker.
def conditional_view(source,defines):
    active=True; stack=[]; output=[]; pos=0
    for match in re.finditer(r'\{\$\s*(IFDEF|IFNDEF|ELSE|ENDIF)\b([^}]*)\}',source,re.I):
        if active: output.append(source[pos:match.start()])
        kind=match.group(1).upper(); value=match.group(2).strip().upper()
        if kind in ['IFDEF','IFNDEF']:
            condition=(value in defines)
            if kind=='IFNDEF': condition=not condition
            stack.append((active,condition)); active=active and condition
        elif kind=='ELSE':
            parent,condition=stack[-1]; active=parent and not condition
        else:
            parent,_=stack.pop(); active=parent
        pos=match.end()
    if active: output.append(source[pos:])
    if stack: raise AssertionError('Unbalanced conditionals')
    return ''.join(output)

class SourcePaths(unittest.TestCase):
    def test_no_private_loads_in_standalone(self):
        names=['server/kvm_session_guard.pas','server/kvm_turbojpeg.pas',
               'client/kvm_turbojpeg_decode.pas','shared/kvm_codec.pas',
               'server/kvm_capture_dxgi.pas','server/kvm_capture_mac.pas','server/kvm_wayland.pas']
        for os_name in ['LINUX','DARWIN','WINDOWS']:
            for extra in [set(),{'KVM_STATIC_CODEC','KVM_STATIC_PORTAL','KVM_STATIC_DXGI'}]:
                defines={'KVM_STANDALONE',os_name}|extra
                for name in names:
                    code=conditional_view((ROOT/name).read_text(),defines)
                    self.assertNotIn('LoadLibrary(',code,name)
                    self.assertNotIn('GetProcedureAddress(',code,name)
    def test_dynamic_profile_still_explicit(self):
        source=(ROOT/'server/kvm_turbojpeg.pas').read_text()
        self.assertIn('LoadLibrary(',conditional_view(source,{'LINUX'}))
    def test_policy_not_disabled(self):
        source=(ROOT/'server/kvm_session_guard.pas').read_text()
        self.assertIn("Strict:=Policy='strict'",source)
        self.assertIn('(NewState=KVM_SESSION_UNKNOWN) and not Strict',source)
        self.assertIn('KvmSessionOpenEx',source)

if __name__=='__main__': unittest.main(verbosity=2)

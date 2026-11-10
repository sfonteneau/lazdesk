"""Tests targeted to the Windows Installer import typo in mORMot2."""
import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,file)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

fix=load('fix_mormot_msi_import',ROOT/'tools/fix_mormot_msi_import.py')
audit=load('audit_msi_symbols',ROOT/'tools/audit_standalone.py')
builder=load('standalone_builder',ROOT/'build/build_standalone.py')

class MsiImportTests(unittest.TestCase):
    SAMPLE = (b'function MsiEnumProductA(iProductIndex: cardinal; lpProductBuf: PAnsiChar): cardinal; stdcall;\r\n'
              b'function MsiEnumProductA; external msidll;\r\n'
              b'if MsiEnumProductA(0, ptr) = 0 then begin end;\r\n')

    def test_changes_only_external_import(self):
        new,status=fix.change_import(self.SAMPLE)
        self.assertEqual(status,'corrige')
        self.assertIn(b"function MsiEnumProductA; external msidll name 'MsiEnumProductsA';",new)
        self.assertIn(b'function MsiEnumProductA(iProductIndex:',new)
        self.assertIn(b'if MsiEnumProductA(0, ptr)',new)
        self.assertEqual(new.count(b'MsiEnumProductsA'),1)
        self.assertEqual(new.count(b'\r\n'),3)

    def test_idempotent(self):
        new,_=fix.change_import(self.SAMPLE)
        self.assertEqual(fix.change_import(new),(new,'deja-corrige'))

    def test_reject_unexpected_version(self):
        with self.assertRaises(ValueError):
            fix.change_import(b'function MsiEnumProductA; external otherdll;')

    def test_patch_file_and_backup_preserves_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            source=root/'src/lib/mormot.lib.sspi.pas'
            source.parent.mkdir(parents=True)
            source.write_bytes(self.SAMPLE+b'\xff\xfe\r\n')
            _,status,backup=fix.patch(root)
            self.assertEqual(status,'corrige')
            self.assertEqual(backup.read_bytes(),self.SAMPLE+b'\xff\xfe\r\n')
            self.assertIn(b'MsiEnumProductsA',source.read_bytes())
            self.assertTrue(source.read_bytes().endswith(b'\xff\xfe\r\n'))
            _,status,_=fix.patch(root)
            self.assertEqual(status,'deja-corrige')

    def test_check_cli_reports_bad_and_good_without_changes(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            src=root/'src/lib/mormot.lib.sspi.pas'
            src.parent.mkdir(parents=True)
            src.write_bytes(self.SAMPLE)
            argv=[sys.executable,str(ROOT/'tools/fix_mormot_msi_import.py'),'--check',str(root)]
            bad=subprocess.run(argv,capture_output=True,text=True)
            self.assertNotEqual(bad.returncode,0)
            self.assertEqual(src.read_bytes(),self.SAMPLE)
            fix.patch(root)
            good=subprocess.run(argv,capture_output=True,text=True)
            self.assertEqual(good.returncode,0,good.stderr)
            self.assertIn('OK: import MSI valide',good.stdout)

    def test_builder_detects_legacy_helper_with_clear_message(self):
        with tempfile.TemporaryDirectory() as d:
            legacy=Path(d)/'fix_mormot_msi_import.py'
            legacy.write_text('import argparse\np=argparse.ArgumentParser()\np.add_argument("mormot")\np.parse_args()\n',encoding='utf-8')
            with self.assertRaises(builder.BuildError) as raised:
                builder.require_mormot_fixer_check(legacy)
            self.assertIn('versions incompatibles',str(raised.exception).lower())
            self.assertIn('tools/fix_mormot_msi_import.py',str(raised.exception))

    def test_builder_accepts_updated_helper(self):
        builder.require_mormot_fixer_check(ROOT/'tools/fix_mormot_msi_import.py')

    def test_windows_builder_explicit_rebuild_guards(self):
        content=(ROOT/'build/build_standalone.py').read_text(encoding='utf-8')
        self.assertIn("'--fix-mormot-msi'",content)
        self.assertIn("'--check'",content)
        self.assertIn('mormot_package])',content)
        self.assertIn('register_lazarus_package_link(laz, mormot_package)', content)
        self.assertNotIn("'--add-package-link='+str(mormot_package)",content)
        self.assertIn('mORMot2 utilise:',content)

    def test_lazbuild_package_link_uses_separate_positional_path(self):
        # Regression: lazbuild 4.8 rejects --add-package-link=<.lpk> and
        # a single argument containing both option and path.
        executable = r'C:\lazarus_4_8\lazarus\lazbuild.exe'
        package = Path(r'C:\tranquilit\mORMot2\packages\lazarus\mormot2.lpk')
        with patch.object(builder,'run') as execute:
            builder.register_lazarus_package_link(executable, package)
        execute.assert_called_once_with([executable, '--add-package-link', package])

    def test_lazbuild_package_path_with_spaces_keeps_one_argument(self):
        executable = r'C:\Program Files\Lazarus\lazbuild.exe'
        package = Path(r'C:\Sources de projets\mORMot2\packages\lazarus\mormot2.lpk')
        with patch.object(builder,'run') as execute:
            builder.register_lazarus_package_link(executable, package)
        execute.assert_called_once_with([executable, '--add-package-link', package])

    def test_audit_rejects_invalid_symbol(self):
        self.assertTrue(audit.invalid_imports('PE',
            'DLL Name: msi.dll\n    00446d24  <none>  0000  MsiEnumProductA\n'))
        self.assertFalse(audit.invalid_imports('PE',
            'DLL Name: msi.dll\n    00446d24  <none>  0000  MsiEnumProductsA\n'))
        self.assertFalse(audit.invalid_imports('ELF','MsiEnumProductA'))

if __name__=='__main__': unittest.main(verbosity=2)

#!/usr/bin/env python3
"""The builder must use the upstream mORMot2 package unchanged."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('standalone_builder', ROOT / 'build/build_standalone.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

class UpstreamMormotIntegration(unittest.TestCase):
    def test_removed_source_patch(self):
        self.assertFalse((ROOT/'tools/fix_mormot_msi_import.py').exists())
        code=(ROOT/'build/build_standalone.py').read_text(encoding='utf-8')
        self.assertNotIn('fix_mormot_msi_import',code)
        self.assertNotIn('fix_mormot_msi',code)
        self.assertNotIn('--fix-mormot-msi',code)
        self.assertNotIn('require_mormot_fixer_check',code)
        self.assertIn("mormot_root / 'packages/lazarus/mormot2.lpk'",code)
        self.assertIn('register_lazarus_package_link(laz, mormot_package)',code)
        self.assertIn('mormot_package])',code)

    def test_help_keeps_package_selection(self):
        completed=subprocess.run([sys.executable, str(ROOT/'build/build_standalone.py'), '--help'],
                                 capture_output=True,text=True)
        self.assertEqual(completed.returncode,0,completed.stderr)
        self.assertIn('--mormot-dir',completed.stdout)
        self.assertNotIn('--fix-mormot-msi',completed.stdout)

    def test_lazbuild_receives_package_as_separate_argument(self):
        executable=r'C:\lazarus_4_8\lazarus\lazbuild.exe'
        package=Path(r'C:\tranquilit\mORMot2\packages\lazarus\mormot2.lpk')
        with patch.object(builder,'run') as execute:
            builder.register_lazarus_package_link(executable,package)
        execute.assert_called_once_with([executable,'--add-package-link',package])

if __name__ == '__main__': unittest.main(verbosity=2)

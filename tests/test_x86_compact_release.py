"""Build-option regression checks (no Windows toolchain needed)."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('compact_standalone_builder', ROOT / 'build/build_standalone.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

class CompactReleaseTests(unittest.TestCase):
    def test_win32_x86_both_projects_stripped_smart_static(self):
        with tempfile.TemporaryDirectory() as tmp:
            sandbox = Path(tmp)
            for role, name in [('server','LazDeskServer'),('client','LazDeskClient')]:
                (sandbox / role).mkdir()
                shutil.copy2(ROOT / role / (name + '.lpi'), sandbox / role)
            previous = b.ROOT
            try:
                b.ROOT = sandbox
                projects = b.make_projects('i386-win32', [], 'win32', linker_flags=['-Xe'])
                for project in projects:
                    root = ET.parse(project)
                    opts = root.find('.//CustomOptions').get('Value').split()
                    self.assertEqual(opts[:7], ['-dKVM_STANDALONE', '-O2', '-Os', '-g-', '-CX', '-XX', '-Xs'])
                    self.assertIn('-Xe', opts)
                    self.assertEqual(root.find('.//CodeGeneration/TargetCPU').get('Value'), 'i386')
                    self.assertTrue(root.find('.//Target/Filename').get('Value').endswith('.exe'))
                # x64 and non-Windows builds keep their prior settings.
                for cpu, os_name in [('x86_64', 'win64'), ('x86_64', 'linux')]:
                    projects = b.make_projects(cpu + '-' + os_name, [], os_name, linker_flags=['-Xe'] if os_name == 'win64' else [])
                    for project in projects:
                        opts = ET.parse(project).find('.//CustomOptions').get('Value').split()
                        self.assertNotIn('-Os', opts)
                        self.assertNotIn('-Xs', opts)
            finally:
                b.ROOT = previous

if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Tests for macOS bundle packaging (can be run on Linux without Lazarus)."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


package = module('package_macos', ROOT / 'build/package_macos_app.py')
builder = module('macos_builder', ROOT / 'build/build_standalone.py')


class MacBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lazdesk-test-mac-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / 'client' / 'LazDeskClient'
        self.binary.parent.mkdir()
        self.binary.write_bytes(b'fake-MachO-binary')
        self.lang = self.root / 'client' / 'languages'
        self.lang.mkdir()
        for lang in ('en','fr'):
            (self.lang / f'LazDeskClient.{lang}.po').write_text('msgid ""\nmsgstr ""\n')
        self.bundle = self.root / 'dist' / 'LazDeskClient.app'

    def test_bundle_contains_executable_plist_and_lazarus_catalogs(self):
        result = package.package_viewer(self.binary, self.bundle, self.lang)
        self.assertEqual(result, self.bundle)
        exe = self.bundle / 'Contents/MacOS/LazDeskClient'
        self.assertEqual(exe.read_bytes(), b'fake-MachO-binary')
        self.assertTrue(exe.stat().st_mode & 0o111)
        self.assertFalse(exe.is_symlink())
        with (self.bundle / 'Contents/Info.plist').open('rb') as fp:
            info = plistlib.load(fp)
        self.assertEqual(info['CFBundleExecutable'], 'LazDeskClient')
        self.assertEqual(info['CFBundleName'], 'LazDesk')
        self.assertEqual(info['CFBundlePackageType'], 'APPL')
        self.assertEqual(info['NSPrincipalClass'], 'TCocoaApplication')
        self.assertFalse(info['LSUIElement'])
        self.assertEqual((self.bundle / 'Contents/PkgInfo').read_bytes(), b'APPL????')
        for lang in ('en','fr'):
            self.assertTrue((self.bundle / f'Contents/Resources/languages/LazDeskClient.{lang}.po').is_file())

    def test_repackage_replaces_stale_files_and_binary(self):
        package.package_viewer(self.binary, self.bundle, self.lang)
        (self.bundle / 'Contents/Resources/stale.txt').write_text('old')
        self.binary.write_bytes(b'new-binary')
        package.package_viewer(self.binary, self.bundle, self.lang)
        self.assertFalse((self.bundle / 'Contents/Resources/stale.txt').exists())
        self.assertEqual((self.bundle / 'Contents/MacOS/LazDeskClient').read_bytes(), b'new-binary')

    def test_missing_translation_does_not_destroy_old_app(self):
        package.package_viewer(self.binary, self.bundle, self.lang)
        (self.lang / 'LazDeskClient.fr.po').unlink()
        with self.assertRaises(package.BundleError):
            package.package_viewer(self.binary, self.bundle, self.lang)
        self.assertTrue((self.bundle / 'Contents/Info.plist').is_file())

    def test_macos_script_args_and_help(self):
        script = ROOT / 'build/build_macos.sh'
        self.assertEqual(subprocess.run(['sh','-n',script]).returncode,0)
        help_result = subprocess.run(['sh',script,'--help'],capture_output=True,text=True)
        self.assertEqual(help_result.returncode,0)
        self.assertIn('--lazbuild',help_result.stdout)
        self.assertIn('LAZBUILD',help_result.stdout)
        self.assertIn('LazDeskClient.app',help_result.stdout)
        missing = subprocess.run(['sh',script,'--lazbuild'],capture_output=True,text=True)
        self.assertEqual(missing.returncode,2)
        self.assertIn('Missing argument',missing.stderr)

    def test_macos_build_accepts_lazbuild_path_with_spaces(self):
        # Exercise the POSIX shell quoting and end-to-end packaging without
        # requiring macOS, the LCL or Free Pascal on the CI host.
        project = self.root / 'demo project'
        for folder in ('build', 'native/macos', 'client', 'server'):
            (project / folder).mkdir(parents=True)
        shutil.copy2(ROOT / 'build/build_macos.sh', project / 'build/build_macos.sh')
        shutil.copy2(ROOT / 'build/package_macos_app.py', project / 'build/package_macos_app.py')
        (project / 'native/macos/build.sh').write_text('#!/bin/sh\nexit 0\n')
        for role,app in (('server','LazDeskServer'),('client','LazDeskClient')):
            (project / role / (app + '.lpi')).write_text('<CONFIG/>')
        shutil.copytree(self.lang, project / 'client/languages')
        fake_lazarus = self.root / 'installed Lazarus' / 'lazbuild'
        fake_lazarus.parent.mkdir()
        fake_lazarus.write_text(
            '#!/bin/sh\n'
            'for item in "$@"; do\n'
            '  case "$item" in\n'
            '    */client/LazDeskClient.lpi)\n'
            '      app="${item%.lpi}"\n'
            '      printf "fake-compiled-client" > "$app"\n'
            '      chmod +x "$app"\n'
            '      ;;\n'
            '  esac\n'
            'done\n'
        )
        fake_lazarus.chmod(0o755)
        completed = subprocess.run(['sh', project / 'build/build_macos.sh',
                                    '--lazbuild', str(fake_lazarus)],
                                   capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        output = project / 'dist/macos/LazDeskClient.app'
        self.assertEqual((output / 'Contents/MacOS/LazDeskClient').read_bytes(), b'fake-compiled-client')
        self.assertTrue((output / 'Contents/Info.plist').is_file())

    def test_mac_lpi_and_generated_standalone_bundle_settings(self):
        client = ET.parse(ROOT / 'client/LazDeskClient.lpi')
        self.assertEqual(client.find('.//General/UseAppBundle').get('Value'), 'True')
        self.assertEqual(client.find('.//General/NSPrincipalClass').get('Value'), 'TCocoaApplication')
        with tempfile.TemporaryDirectory() as tmp:
            temp_root=Path(tmp)
            for role,app in [('server','LazDeskServer'),('client','LazDeskClient')]:
                (temp_root/role).mkdir()
                shutil.copy2(ROOT/role/(app+'.lpi'),temp_root/role)
            original=builder.ROOT
            try:
                builder.ROOT=temp_root
                projects=builder.make_projects('aarch64-darwin',[],'darwin')
                flags={p.parent.name: ET.parse(p).find('.//General/UseAppBundle').get('Value') for p in projects}
                self.assertEqual(flags, {'server':'False','client':'True'})
                generated_client = ET.parse(projects[1])
                self.assertEqual(generated_client.find('.//General/NSPrincipalClass').get('Value'), 'TCocoaApplication')
                projects=builder.make_projects('x86_64-linux',[],'linux')
                flags={p.parent.name: ET.parse(p).find('.//General/UseAppBundle').get('Value') for p in projects}
                self.assertEqual(flags, {'server':'False','client':'False'})
            finally:
                builder.ROOT=original

    def test_cocoa_menu_stays_assigned_in_fullscreen_and_bundle_language_search(self):
        source=(ROOT/'client/kvm_view_form.pas').read_text()
        self.assertIn('{$IFDEF DARWIN}', source)
        self.assertIn('if FFullScreenMode then Menu:=nil else Menu:=FMainMenu', source)
        self.assertIn('Cocoa owns one global menu bar', source)
        i18n=(ROOT/'client/kvm_viewer_i18n.pas').read_text()
        self.assertIn('../Resources/languages',i18n)
        self.assertIn('LAZDESK_LANG_DIR',i18n)


if __name__ == '__main__':
    unittest.main(verbosity=2)

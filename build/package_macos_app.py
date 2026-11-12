#!/usr/bin/env python3
"""Package the native Cocoa LazDesk Viewer as a self-contained macOS .app.

This is packaging, not code signing/notarization.  The compiled Lazarus
executable remains a native Mach-O binary; PO catalogs are resources.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile


class BundleError(RuntimeError):
    pass


def package_viewer(executable: Path, output: Path, languages: Path) -> Path:
    executable = executable.resolve()
    output = output.absolute()
    languages = languages.resolve()
    if output.suffix != '.app' or output.name != 'LazDeskClient.app':
        raise BundleError('Output must be a LazDeskClient.app directory')
    if not executable.is_file() or executable.name != 'LazDeskClient':
        raise BundleError('Compiled LazDeskClient executable not found: ' + str(executable))
    if not languages.is_dir():
        raise BundleError('Viewer translation directory not found: ' + str(languages))
    for locale in ('en', 'fr'):
        if not (languages / f'LazDeskClient.{locale}.po').is_file():
            raise BundleError('Missing viewer translation: LazDeskClient.' + locale + '.po')

    output.parent.mkdir(parents=True, exist_ok=True)
    # Stage beside the destination so a failed copy never leaves a half-built .app.
    with tempfile.TemporaryDirectory(prefix='.lazdesk-bundle-', dir=output.parent) as temp:
        bundle = Path(temp) / 'LazDeskClient.app'
        macos = bundle / 'Contents' / 'MacOS'
        resources = bundle / 'Contents' / 'Resources' / 'languages'
        macos.mkdir(parents=True)
        resources.mkdir(parents=True)
        target = macos / 'LazDeskClient'
        shutil.copy2(executable, target)
        target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        # LCL/Cocoa creates the application menu; macOS recognizes it as a
        # normal foreground app (LSUIElement = false), rather than an agent.
        info = {
            'CFBundleDevelopmentRegion': 'en',
            'CFBundleExecutable': 'LazDeskClient',
            'CFBundleIdentifier': 'org.lazdesk.client',
            'CFBundleInfoDictionaryVersion': '6.0',
            'CFBundleName': 'LazDesk',
            'CFBundleDisplayName': 'LazDesk',
            'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.0.0',
            'CFBundleVersion': '1',
            'LSMinimumSystemVersion': '12.3',
            'LSUIElement': False,
            'NSHighResolutionCapable': True,
            'NSPrincipalClass': 'TCocoaApplication',
        }
        with (bundle / 'Contents' / 'Info.plist').open('wb') as fp:
            plistlib.dump(info, fp, sort_keys=False)
        (bundle / 'Contents' / 'PkgInfo').write_bytes(b'APPL????')
        for catalog in languages.iterdir():
            if catalog.is_file() and catalog.suffix in ('.po', '.mo'):
                shutil.copy2(catalog, resources / catalog.name)

        if output.is_symlink() or output.is_file():
            output.unlink()
        elif output.exists():
            shutil.rmtree(output)
        bundle.rename(output)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--languages', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = package_viewer(args.executable, args.output, args.languages)
    except (BundleError, OSError) as exc:
        parser.exit(2, 'ERROR: ' + str(exc) + '\n')
    print('macOS Cocoa viewer bundle: ' + str(result))


if __name__ == '__main__':
    main()

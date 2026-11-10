#!/usr/bin/env python3
"""Build one LazDesk executable per application, with no private shared modules.

No downloads, no run-time extraction, no global -static. Native archives must
match the selected FPC target (--arch x86/x64 on Windows). Optional system FFmpeg/GIO/PipeWire remain dynamic
on Linux; the default X11/JPEG profile does not need those libraries.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

class BuildError(RuntimeError):
    pass

def run(argv: list[str | Path], *, capture: bool = False, cwd: Path | None = None,
        clean_windows_runtime: bool = False) -> str:
    args = [str(a) for a in argv]
    display = subprocess.list2cmdline(args) if os.name == 'nt' else shlex.join(args)
    print('+ ' + display, flush=True)
    env = os.environ.copy()
    env['LC_ALL'] = 'C'
    if clean_windows_runtime:
        # The probe must not accidentally find MinGW DLLs from the developer's
        # PATH.  Otherwise it passes locally but fails after being copied to a
        # machine with only Windows system DLLs installed.
        if os.name != 'nt':
            raise BuildError('The isolated Windows runtime probe requires Windows')
        windows = env.get('SystemRoot') or env.get('WINDIR')
        if not windows:
            raise BuildError('SystemRoot/WINDIR missing: isolated Windows probe unavailable')
        env['PATH'] = os.pathsep.join([str(Path(windows) / 'System32'), windows])
    p = subprocess.run(args, cwd=cwd or ROOT, text=True, errors='replace', env=env,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None)
    if p.returncode:
        raise BuildError(f'Command failed ({p.returncode}): {display}\n{p.stdout or ""}')
    return (p.stdout or '').strip()

def register_lazarus_package_link(lazbuild: str, package: Path) -> None:
    """Register the exact .lpk source tree using lazbuild's *flag + file* syntax.

    Lazarus 4.8 handles --add-package-link as a flag and reads .lpk paths
    from positional arguments.  Passing '--add-package-link=<path>' (or a
    combined '--add-package-link <path>' string) causes 'Invalid option'.
    Let subprocess quote each argument separately on Windows.
    """
    run([lazbuild, '--add-package-link', package])


def tool(name: str) -> str:
    p = shutil.which(name)
    if not p:
        raise BuildError(f'Tool not found: {name}. Install the build tools, not just the runtimes.')
    return str(Path(p).absolute())

def host_target(arch: str = 'native') -> tuple[str, str]:
    """Select the target, not the Python process bitness.

    Windows permits an explicit x86 build on an x64 host. This does not
    install a cross compiler or make a 64-bit GCC produce 32-bit objects.
    Non-Windows builds remain native to avoid changing their SDK policy.
    """
    if arch not in ('native', 'x86', 'x64'):
        raise BuildError('Unknown architecture: ' + arch)
    system = platform.system()
    machine = platform.machine().lower()
    if system == 'Windows':
        # A 32-bit Python process can run on a 64-bit Windows installation.
        machine = os.environ.get('PROCESSOR_ARCHITEW6432', machine).lower()
    host_cpu = {'amd64':'x86_64', 'x86_64':'x86_64', 'x86':'i386',
                'i386':'i386', 'i486':'i386', 'i586':'i386', 'i686':'i386',
                'arm64':'aarch64', 'aarch64':'aarch64'}.get(machine)
    cpu = {'x86':'i386', 'x64':'x86_64'}.get(arch, host_cpu)
    if system == 'Windows':
        if host_cpu not in ('i386', 'x86_64') or cpu not in ('i386', 'x86_64'):
            raise BuildError('Windows: only --arch x86 and --arch x64 targets are supported.')
        if host_cpu == 'i386' and cpu == 'x86_64':
            raise BuildError('x64 probes require 64-bit Windows; no native test will be skipped.')
        return cpu, 'win32' if cpu == 'i386' else 'win64'
    os_name = {'Linux':'linux', 'Darwin':'darwin'}.get(system)
    if not os_name or host_cpu not in ('x86_64', 'aarch64') or cpu != host_cpu:
        raise BuildError('Linux/macOS: native x86_64/aarch64 builds only. --arch x86 is for Windows.')
    return cpu, os_name


def is_windows(os_name: str) -> bool:
    return os_name in ('win32', 'win64')


def fpc_target_flags(cpu: str, os_name: str) -> list[str]:
    return ['-P' + cpu, '-T' + os_name]


def check_fpc_target(fpc: str, cpu: str, os_name: str) -> None:
    flags = fpc_target_flags(cpu, os_name)
    try:
        fc = run([fpc, *flags, '-iTP'], capture=True).splitlines()[-1].strip()
        fo = run([fpc, *flags, '-iTO'], capture=True).splitlines()[-1].strip()
    except (BuildError, IndexError) as exc:
        raise BuildError(
            f'FPC cannot target {cpu}-{os_name}. --arch does not install compilers. '
            'Install the compiler and units for this target, or select the appropriate fpc.exe '
            'with --fpc. Details: ' + str(exc)) from exc
    if (fc, fo) != (cpu, os_name):
        raise BuildError(f'FPC reports {fc}-{fo}; requested target is {cpu}-{os_name}. '
                         'Select the correct --fpc; the target will not change silently.')


def compiler_prefix(cc: str) -> str:
    # i686-w64-mingw32-gcc.exe -> i686-w64-mingw32- ; gcc.exe -> empty.
    stem = Path(cc).stem
    return stem[:-3] if stem.endswith('gcc') else ''


def select_c_tool(name: str, explicit: str | None, bin_dir: Path | None,
                  cc: str | None = None, *, cpu: str = '') -> str:
    """Prefer the selected SDK over an unrelated Strawberry/MSYS installation."""
    if explicit:
        return tool(explicit)
    directory = bin_dir.resolve() if bin_dir else (Path(cc).parent if cc else None)
    if directory:
        if not directory.is_dir():
            raise BuildError('Toolchain directory not found: ' + str(directory))
        prefix = compiler_prefix(cc) if cc else (
            'i686-w64-mingw32-' if cpu == 'i386' else 'x86_64-w64-mingw32-')
        for candidate in dict.fromkeys([prefix + name, name]):
            for suffix in ('.exe', ''):
                path = directory / (candidate + suffix)
                if path.is_file():
                    return tool(str(path))
        # For an explicit --toolchain-bin, never quietly fall back to PATH.
        if bin_dir:
            raise BuildError(f'{name} not found in {directory}. Select a complete MinGW toolchain.')
    if name == 'gcc' and cpu in ('i386', 'x86_64'):
        prefixed = ('i686' if cpu == 'i386' else 'x86_64') + '-w64-mingw32-gcc'
        if shutil.which(prefixed):
            return tool(prefixed)
    return tool(name)


def check_windows_linker(ld: str, cpu: str) -> None:
    """Check the DEFAULT PE output architecture, not the ld.exe file name.

    MSYS2 MINGW32 commonly ships a prefixed GCC but an unprefixed ld.exe.
    Both are valid when ld defaults to the same target as GCC/FPC.
    """
    output = run([ld, '--verbose'], capture=True)
    match = re.search(r'\bOUTPUT_FORMAT\s*\(\s*"?([a-zA-Z0-9_.+-]+)', output)
    fmt = match.group(1) if match else None
    expected = {'i386': 'pei-i386', 'x86_64': 'pei-x86-64'}[cpu]
    if fmt != expected:
        raise BuildError(
            f'Linker incompatible with {cpu}-Windows: {ld} '
            f'reports {fmt or "an unknown format"}; expected {expected}. '
            'Choose a --toolchain-bin for the correct architecture.')


def windows_linker_flags(cc: str, ld: str) -> list[str]:
    """Tell FPC to run the linker name that ACTUALLY exists in MinGW."""
    prefix = compiler_prefix(cc)
    ld_stem = Path(ld).stem
    if ld_stem == prefix + 'ld':
        chosen_prefix = prefix
    elif ld_stem == 'ld':
        chosen_prefix = ''
    else:
        raise BuildError('Linker name not supported by FPC: ' + ld)
    # -XP without an argument resets a cross prefix from fpc.cfg.
    # -FD points at the selected MinGW directory, not Strawberry/PATH.
    return ['-Xe', '-FD' + str(Path(ld).parent), '-XP' + chosen_prefix]


def windows_sdk_library_directories(cc: str) -> list[str]:
    """Find Win32/DXGI import libraries using the *selected* MinGW GCC.

    FPC invokes ld directly (unlike g++), so ld does not inherit GCC's
    implicit library search directories.  Passing -FD to FPC only selects
    the linker executable; it does NOT add <mingw>/lib.  Locate the actual
    SDK archives via GCC rather than assuming the layout of MSYS2.
    """
    required = ('d3d11', 'dxgi', 'dxguid', 'uuid',
                'user32', 'gdi32', 'kernel32', 'advapi32')
    dirs: list[str] = []
    missing: list[str] = []
    for lib in required:
        filename = 'lib' + lib + '.a'
        resolved = run([cc, '-print-file-name=' + filename], capture=True).strip()
        archive = Path(resolved)
        if not archive.is_file() or archive.name.lower() != filename.lower():
            missing.append(filename)
            continue
        directory = str(archive.resolve().parent)
        if directory not in dirs:
            dirs.append(directory)
    if missing:
        raise BuildError(
            'Incomplete MinGW SDK or Windows libraries not found via ' + cc + ': ' +
            ', '.join(missing) + '. Install the Win32/DirectX import archives ' +
            'for the same architecture (--arch x86 => mingw32; x64 => mingw64). ' +
            'Do not substitute x64 archives for x86 archives.')
    return dirs


def option_text(options: list[str]) -> str:
    # Lazarus parses these options, not a POSIX shell. Keep Windows paths
    # containing spaces as a single option. Reject an embedded quote/newline.
    result = []
    for option in options:
        if any(c in option for c in ('"', '\n', '\r')):
            raise BuildError('Option cannot be represented in the Lazarus project: ' + repr(option))
        result.append('"' + option + '"' if any(c.isspace() for c in option) else option)
    return ' '.join(result)


def feature_include(cpu: str, os_name: str, defines: list[str]) -> str:
    cpu_macro = {'i386':'CPU386', 'x86_64':'CPUX86_64', 'aarch64':'CPUAARCH64'}[cpu]
    os_macro = {'linux':'LINUX', 'darwin':'DARWIN', 'win32':'WIN32', 'win64':'WIN64'}[os_name]
    return ('{ Generated for ' + cpu + '-' + os_name + '. Do not copy between architectures. }\n'
            '{$IFNDEF ' + cpu_macro + '}{$FATAL Wrong CPU for standalone archives}{$ENDIF}\n'
            '{$IFNDEF ' + os_macro + '}{$FATAL Wrong OS for standalone archives}{$ENDIF}\n' +
            ''.join('{$DEFINE ' + d + '}\n' for d in defines))


def check_pe_target(path: Path, cpu: str) -> None:
    """Check the PE machine without executing a possibly wrong-CPU file."""
    expected = {'i386':0x014c, 'x86_64':0x8664}[cpu]
    with path.open('rb') as f:
        head = f.read(64)
        if len(head) != 64 or head[:2] != b'MZ':
            raise BuildError('Invalid PE executable: ' + str(path))
        offset = struct.unpack_from('<I', head, 60)[0]
        if offset < 64 or offset > path.stat().st_size - 6:
            raise BuildError('PE header out of bounds: ' + str(path))
        f.seek(offset)
        pe = f.read(6)
    if pe[:4] != b'PE\x00\x00':
        raise BuildError('Invalid PE signature: ' + str(path))
    actual = struct.unpack_from('<H', pe, 4)[0]
    if actual != expected:
        raise BuildError(f'{path}: PE machine 0x{actual:04x}, expected {cpu} (0x{expected:04x})')


def check_windows_archive(path: Path, objdump: str, cpu: str) -> None:
    output = run([objdump, '-f', path], capture=True)
    formats = re.findall(r'file format\s+(\S+)', output)
    allowed = {'i386':{'pe-i386', 'pe-bigobj-i386'},
               'x86_64':{'pe-x86-64', 'pe-bigobj-x86-64'}}[cpu]
    if not formats or any(fmt not in allowed for fmt in formats):
        raise BuildError(f'{path}: object formats {sorted(set(formats))}, expected {cpu} Windows. '
                         'Provide or rebuild libturbojpeg.a for the selected target.')


def audit_binary(path: Path, cpu: str, os_name: str, objdump: str | None = None,
                 report: Path | None = None) -> None:
    options: list[str | Path] = []
    if is_windows(os_name):
        check_pe_target(path, cpu)
        if objdump:
            options += ['--objdump', objdump]
    if report:
        options += ['--report', report]
    run([sys.executable, ROOT/'tools/audit_standalone.py', path, *options])

def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')

def native_archive(cc: str, ar: str, output: Path, source: Path, flags: list[str]) -> None:
    obj = output.with_suffix('.o')
    run([cc, *flags, '-DKVM_STATIC_BUILD', '-c', source, '-o', obj])
    output.unlink(missing_ok=True)
    run([ar, 'rcs', output, obj])

def symbols(nm: str, path: Path) -> str:
    # llvm-nm and GNU nm both support -g; declarations in an import archive
    # are not proof of static implementation. Check actual T/t definitions.
    return run([nm, '-g', path], capture=True)

def assert_archive(path: Path, nm: str, names: list[str]) -> None:
    if not path.is_file():
        raise BuildError(f'Static archive not found: {path}')
    with path.open('rb') as f:
        if f.read(8) != b'!<arch>\n':
            raise BuildError(f'{path}: a complete ar archive (.a) is required, not a DLL/.so or thin archive.')
    table = symbols(nm, path)
    for name in names:
        if not re.search(r'\b[Tt]\s+_?' + re.escape(name) + r'\s*$', table, re.M):
            raise BuildError(f'{path}: missing definition of {name} (wrong SDK or import library).')
    if any(re.search(r'\b_?__imp_' + re.escape(name) + r'\s*$', table, re.M) for name in names):
        raise BuildError(f'{path}: DLL import archive, not a static implementation.')

def system_links(tokens: list[str], *, extra: list[str] | None = None) -> tuple[str, list[str]]:
    """Only accept an explicit, small pkg-config grammar; never silently drop flags."""
    directives: list[str] = []
    search: list[str] = []
    i = 0
    for t in extra or []:
        directives.append('{$LINKLIB ' + t + '}')
    while i < len(tokens):
        arg = tokens[i]
        if arg.startswith('-l') and re.fullmatch(r'[A-Za-z0-9_.+-]+', arg[2:]):
            directives.append('{$LINKLIB ' + arg[2:] + '}')
        elif arg.startswith('-L') and len(arg) > 2:
            search.append(arg[2:])
        elif arg == '-pthread':
            directives.append('{$LINKLIB pthread}')
        elif arg == '-framework' and i + 1 < len(tokens):
            i += 1
            name = tokens[i]
            if not re.fullmatch(r'[A-Za-z0-9_]+', name):
                raise BuildError('Invalid framework name')
            directives.append('{$LINKFRAMEWORK ' + name + '}')
        else:
            raise BuildError(f'Unsupported pkg-config option: {arg!r}. Do not ignore it; adapt the linker configuration for this SDK.')
        i += 1
    return '\n'.join(dict.fromkeys(directives)) + '\n', list(dict.fromkeys(search))

def pkg(name: str, which: str) -> list[str]:
    return shlex.split(run([tool('pkg-config'), which, *name.split()], capture=True))

def check_c_target(cc: str, cpu: str, os_name: str) -> None:
    triple = run([cc, '-dumpmachine'], capture=True).lower()
    arch_ok = ((cpu == 'i386' and re.match(r'i[3-6]86(?:-|$)', triple) is not None) or
               (cpu == 'x86_64' and triple.startswith(('x86_64-', 'amd64-'))) or
               (cpu == 'aarch64' and triple.startswith(('aarch64-', 'arm64-'))))
    os_ok = (('mingw' in triple or 'windows' in triple) if is_windows(os_name) else
             ('darwin' in triple or 'apple' in triple) if os_name == 'darwin' else
             'linux' in triple)
    if not arch_ok or not os_ok:
        raise BuildError(f'Incompatible C target: {cc} reports {triple}; requested {cpu}-{os_name}. '
                         'Choose --toolchain-bin (or --cc) for this architecture. '
                         'No implicit -m32/-m64 and no forced automatic Strawberry selection.')
    if is_windows(os_name) and 'mingw' not in triple:
        raise BuildError('Static Windows: use MinGW-w64 (matching architecture/CRT), not MSVC/clang-cl.')

def make_projects(target: str, search: list[str], os_name: str,
                  *, fpc: str | None = None, linker_flags: list[str] | None = None) -> list[Path]:
    projects = []
    cpu = target.rsplit('-', 1)[0]
    for role, app in [('server','LazDeskServer'), ('client','LazDeskClient')]:
        tree = ET.parse(ROOT / role / (app + '.lpi'))
        root = tree.getroot()
        def set_value(path: str, val: str) -> None:
            element = root
            for name in path.split('/'):
                child = element.find(name)
                if child is None:
                    child = ET.SubElement(element, name)
                element = child
            element.set('Value', val)
        modes = root.find('ProjectOptions/BuildModes')
        assert modes is not None
        modes.clear()
        ET.SubElement(modes, 'Item', Name='Standalone', Default='True')
        native = '../native/static/' + target
        set_value('ProjectOptions/General/UseAppBundle', 'False')
        set_value('CompilerOptions/SearchPaths/IncludeFiles', '../shared;' + native)
        set_value('CompilerOptions/SearchPaths/Libraries', ';'.join([native, *search]))
        set_value('CompilerOptions/SearchPaths/UnitOutputDirectory', 'lib/standalone/' + target)
        suffix = '.exe' if is_windows(os_name) else ''
        set_value('CompilerOptions/Target/Filename', '../dist/' + target + '/' + app + suffix)
        set_value('CompilerOptions/CodeGeneration/TargetCPU', cpu)
        set_value('CompilerOptions/CodeGeneration/TargetOS', os_name)
        if fpc:
            set_value('CompilerOptions/Other/CompilerPath', fpc)
        options = '-dKVM_STANDALONE'
        if os_name == 'darwin':
            options += ' -WM12.3'
        if is_windows(os_name):
            options += ' ' + option_text(linker_flags or ['-Xe'])
        set_value('CompilerOptions/Other/CustomOptions', options)
        arch_suffix = ('_x86' if cpu == 'i386' else '_x64') if is_windows(os_name) else ''
        project = ROOT / role / (app + '_Standalone' + arch_suffix + '.lpi')
        ET.indent(tree, space='  ')
        tree.write(project, encoding='utf-8', xml_declaration=True)
        projects.append(project)
    return projects

def stage_runtime(cc: str, stage: Path, library: str, output_name: str,
                  *, optional: bool = False) -> str | None:
    name = 'lib' + library + '.a'
    path = Path(run([cc, '-print-file-name=' + name], capture=True))
    if not path.is_file():
        if optional:
            return None
        raise BuildError(f'Missing static runtime: {name} ({cc})')
    destination = stage / ('lib' + output_name + '.a')
    shutil.copy2(path, destination)
    return output_name

def merge_crt_archives(ar: str, path: Path, archives: list[Path]) -> None:
    """Merge MinGW support/import libraries into a REAL GNU ar archive.

    FPC's ld invocation includes its generated linkXXXX.res linker script. On
    some native Windows binutils versions, a separate GROUP linker script
    masquerading as libfoo.a triggers the duplicate-script detection bug.
    An ar archive has no scripts and its symbol index handles intra-archive
    references in a single search, including mingwex <-> libgcc <-> msvcrt.

    Import libraries for msvcrt and kernel32 remain imports of system DLLs.
    IMPORTANT: never merge libmingw32.a: it defines _tls_used already owned
    by the FPC RTL (sysinitpas.o).
    """
    if not archives:
        raise BuildError('No CRT archives to merge')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)  # discard stale text GROUP() from prior builds
    entries = []
    for archive in archives:
        if archive.parent.resolve() != path.parent.resolve():
            raise BuildError('CRT archive is outside the staging directory: ' + str(archive))
        if not archive.is_file():
            raise BuildError('Static ar archive missing: ' + str(archive))
        with archive.open('rb') as fp:
            magic = fp.read(8)
        if magic != b'!<arch>\n':
            raise BuildError('Invalid static ar archive: ' + str(archive))
        if not re.fullmatch(r'lib[A-Za-z0-9_+-]+\.a', archive.name):
            raise BuildError('Unsupported library name: ' + archive.name)
        if archive.name in ('libmingw32.a', 'libkvm_mingw32.a'):
            raise BuildError('MinGW startup would conflict with FPC TLS initialization')
        entries.append(archive.name)
    if path.name != 'libkvm_wincrt.a':
        raise BuildError('Unexpected CRT group name')
    # Use paths relative to cwd: Windows paths may contain spaces or accents.
    # MRI input is sent on stdin, not interpreted by cmd.exe or bash.
    commands = 'CREATE ' + path.name + '\n' + ''.join('ADDLIB ' + name + '\n' for name in entries) + 'SAVE\nEND\n'
    process = subprocess.run([str(ar), '-M'], input=commands, cwd=path.parent,
                             text=True, errors='replace', capture_output=True)
    if process.returncode != 0 or not path.is_file():
        raise BuildError('Failed to merge MinGW archives using GNU ar -M: ' +
                         (process.stderr or process.stdout or str(process.returncode)))
    with path.open('rb') as fp:
        magic = fp.read(8)
    if magic != b'!<arch>\n':
        raise BuildError('The merged CRT file is not a binary ar archive')
    # Force a current symbol index, checked again when compiling the real FPC
    # test_standalone_link.exe (not just a GCC native probe).
    run([ar, 's', path])
    members = run([ar, 't', path], capture=True)
    if not members.strip():
        raise BuildError('Merged CRT archive is empty')


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['native','x86','x64'], default='native',
                        help='Windows: x86=i386-win32, x64=x86_64-win64; native uses host architecture')
    parser.add_argument('--toolchain-bin', type=Path,
                        help='MinGW bin folder for the selected target; takes priority over unrelated PATH tools')
    parser.add_argument('--check-toolchain', action='store_true',
                        help='Check FPC/C target and tool selection only; no build or download')
    parser.add_argument('--only', choices=['both','server','client'], default='both')
    parser.add_argument('--with-portal', action='store_true', help='Linux: integrate portal shim; use system GIO/PipeWire')
    parser.add_argument('--with-codec', action='store_true', help='Linux/macOS: integrate FFmpeg shim; use system FFmpeg libraries')
    parser.add_argument('--with-dxgi', action='store_true', help='Windows x86/x64: integrate DXGI and MinGW C++ runtimes (experimental)')
    parser.add_argument('--turbojpeg-archive', type=Path, default=os.environ.get('TURBOJPEG_STATIC'))
    parser.add_argument('--turbojpeg-source', type=Path, help='Local libjpeg-turbo source tree to compile with SIMD')
    parser.add_argument('--prepare-only', action='store_true', help='Build native archives and generate standalone .lpi, without invoking Lazarus')
    parser.add_argument('--skip-smoke', action='store_true', help='Do not compile/run the Pascal native-link smoke test')
    parser.add_argument('--fpc', default=os.environ.get('FPC'), help='FPC driver (fpc.exe); the selected target compiler and RTL must be installed')
    parser.add_argument('--lazbuild', default=os.environ.get('LAZBUILD','lazbuild'))
    parser.add_argument('--cc', default=None)
    parser.add_argument('--cxx', default=None)
    parser.add_argument('--ar', default=None)
    parser.add_argument('--nm', default=None)
    parser.add_argument('--objdump', default=None, help='PE/archive inspector from the selected MinGW SDK')
    parser.add_argument('--widgetset', default=None)
    parser.add_argument('--mormot-dir', type=Path, default=os.environ.get('MORMOT2_DIR'),
                        help='EXACT mORMot2 root (contains packages/lazarus/mormot2.lpk); require the Lazarus package link')
    args = parser.parse_args(argv)
    cpu, os_name = host_target(args.arch)
    print(f'Requested target: {cpu}-{os_name} (--arch {args.arch})', flush=True)
    target = cpu + '-' + os_name
    if args.with_portal and os_name != 'linux':
        raise BuildError('--with-portal requires Linux')
    if args.with_dxgi and not is_windows(os_name):
        raise BuildError('--with-dxgi requires Windows x86/x64')
    if args.with_codec and is_windows(os_name):
        raise BuildError('The supplied standalone Windows profile uses JPEG. Static Windows FFmpeg is not automated: do not disguise its DLLs as system libraries.')
    if args.only == 'client' and (args.with_portal or args.with_dxgi):
        raise BuildError('Portal/DXGI are server options, not client options')
    if args.turbojpeg_archive and args.turbojpeg_source:
        raise BuildError('Select --turbojpeg-archive OR --turbojpeg-source')
    # An explicit SDK folder overrides ambient CC/AR/etc. Individual CLI
    # switches override the folder. Without a folder, keep environment support.
    def selected(value: str | None, variable: str) -> str | None:
        return value or (os.environ.get(variable) if not args.toolchain_bin else None)
    cc = select_c_tool('gcc' if is_windows(os_name) else 'cc', selected(args.cc, 'CC'),
                       args.toolchain_bin, cpu=cpu)
    check_c_target(cc, cpu, os_name)
    ar = select_c_tool('ar', selected(args.ar, 'AR'), args.toolchain_bin, cc, cpu=cpu)
    nm = select_c_tool('nm', selected(args.nm, 'NM'), args.toolchain_bin, cc, cpu=cpu)
    objdump = None
    linker_flags: list[str] = []
    if is_windows(os_name):
        objdump = select_c_tool('objdump', selected(args.objdump, 'OBJDUMP'), args.toolchain_bin, cc, cpu=cpu)
        ld = select_c_tool('ld', None, args.toolchain_bin, cc, cpu=cpu)
        check_windows_linker(ld, cpu)
        linker_flags = windows_linker_flags(cc, ld)
    fpc = None
    laz = None
    fpc_name = args.fpc or 'fpc'
    if not args.prepare_only or args.check_toolchain or args.fpc or shutil.which(fpc_name):
        fpc = tool(fpc_name)
        check_fpc_target(fpc, cpu, os_name)
    if args.check_toolchain:
        print('FPC, GCC and the PE linker report the requested target; ar/nm/objdump found.')
        print('No executable linked: RTL/LCL, TurboJPEG and mORMot2 still need build-time validation.')
        return 0
    if not args.prepare_only:
        laz = tool(args.lazbuild)
    # --mormot-dir identifies the upstream package for Lazarus.  Never edit,
    # patch or inspect third-party mORMot2 sources from the LazDesk builder.
    # A final executable-import audit still catches incompatible old PPUs.
    mormot_package = None
    if args.mormot_dir:
        mormot_root = args.mormot_dir.resolve()
        mormot_package = mormot_root / 'packages/lazarus/mormot2.lpk'
        if not mormot_package.is_file():
            raise BuildError('mORMot2 package not found: '+str(mormot_package))
    stage = ROOT / 'native/static' / target
    stage.mkdir(parents=True, exist_ok=True)
    # Removing the generated feature include FIRST prevents use of stale
    # features if a later native build fails.
    (stage / 'kvm_standalone_features.inc').unlink(missing_ok=True)
    search: list[str] = []
    if is_windows(os_name) and args.with_dxgi:
        # FPC uses ld.exe directly and therefore misses GCC's SDK search
        # directories unless they are propagated into the generated .lpi
        # and the standalone Pascal smoke link (both consume `search`).
        search.extend(windows_sdk_library_directories(cc))
        print('MinGW DXGI/Win32 libraries: ' + '; '.join(search), flush=True)
    defines: list[str] = []
    cflags = ['-std=c11','-O2','-Wall','-Wextra','-Wno-misleading-indentation']
    if not is_windows(os_name):
        cflags += ['-fPIC']
    if os_name == 'darwin':
        cflags += ['-arch','arm64' if cpu=='aarch64' else 'x86_64','-mmacosx-version-min=12.3']
    if args.turbojpeg_source:
        source = args.turbojpeg_source.resolve()
        if not (source/'CMakeLists.txt').is_file():
            raise BuildError('Incomplete libjpeg-turbo source')
        cmake = tool('cmake')
        build = stage / 'jpeg-build'
        flags = ['-DENABLE_SHARED=OFF','-DENABLE_STATIC=ON','-DWITH_TURBOJPEG=ON',
                 '-DWITH_JAVA=OFF','-DWITH_SIMD=ON','-DREQUIRE_SIMD=ON',
                 '-DWITH_SYSTEM_SPNG=OFF','-DWITH_SYSTEM_ZLIB=OFF','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
                 '-DCMAKE_C_COMPILER=' + Path(cc).as_posix(), '-DCMAKE_AR=' + Path(ar).as_posix()]
        if cpu in ('i386', 'x86_64'):
            flags += ['-DCMAKE_ASM_NASM_COMPILER=' + Path(tool('nasm')).as_posix()]
        if is_windows(os_name):
            flags += ['-G','MinGW Makefiles',
                      '-DCMAKE_ASM_NASM_OBJECT_FORMAT=' + ('win32' if cpu == 'i386' else 'win64')]
            # Use the same SDK for resource compilation; absolute CMake paths
            # are normalized for Windows instead of interpreted as escapes.
            rc = select_c_tool('windres', None, args.toolchain_bin, cc, cpu=cpu)
            flags += ['-DCMAKE_RC_COMPILER=' + Path(rc).as_posix()]
            make = select_c_tool('mingw32-make', None, args.toolchain_bin, cc, cpu=cpu)
            flags += ['-DCMAKE_MAKE_PROGRAM=' + Path(make).as_posix()]
        elif os_name == 'darwin':
            flags += ['-DCMAKE_OSX_ARCHITECTURES=' + ('arm64' if cpu=='aarch64' else 'x86_64'),
                      '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.3']
        run([cmake,'-S',source,'-B',build,*flags])
        run([cmake,'--build',build,'--config','Release','--target','turbojpeg-static','--parallel',str(min(os.cpu_count() or 2,8))])
        found = list(build.rglob('libturbojpeg.a'))
        if len(found) != 1:
            raise BuildError(f'Expected libturbojpeg.a, found: {found}')
        jpeg = found[0]
    elif args.turbojpeg_archive:
        jpeg = args.turbojpeg_archive.resolve()
    else:
        jpeg = Path(run([cc,'-print-file-name=libturbojpeg.a'],capture=True))
        if not jpeg.is_file() and shutil.which('pkg-config'):
            p = subprocess.run(['pkg-config','--variable=libdir','libturbojpeg'],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            candidate = Path(p.stdout.strip()) / 'libturbojpeg.a'
            if p.returncode==0 and candidate.is_file():
                jpeg=candidate
    assert_archive(jpeg,nm,['tjInitCompress','tjInitDecompress','tjCompress2',
                           'tjDecompress2','tjDecompressHeader3','tjBufSize','tjDestroy','tjGetErrorStr2'])
    if is_windows(os_name):
        check_windows_archive(jpeg, objdump, cpu)
    destination = stage / 'libkvm_turbojpeg.a'
    if jpeg.resolve() != destination.resolve():
        shutil.copy2(jpeg,destination)
    turbo_links = ['{$LINKLIB c}', '{$LINKLIB m}'] if not is_windows(os_name) else []
    if is_windows(os_name):
        # Discard a stale archive left by earlier versions of this builder.
        # Never link the MinGW executable CRT startup into the FPC program.
        (stage/'libkvm_mingw32.a').unlink(missing_ok=True)
        # The FPC Win32 RTL supplies the entry point and TLS slot (_tls_used).
        # Linking all of libmingw32.a pulls tlssup.o and conflicts with FPC.
        # TurboJPEG may still need mingwex, libgcc, C runtime and Win32 imports.
        # mingwex/msvcrt/libgcc refer to one another (notably __divdi3 in x86).
        # A genuine combined ar archive resolves the circular references without
        # introducing another linker script into the FPC linkXXXX.res.
        crt_archives: list[Path] = []
        for lib in ('mingwex', 'gcc', *(['gcc_eh'] if cpu == 'i386' else []),
                    'msvcrt', 'kernel32'):
            # Real .a archives, NOT GNU ld scripts: the FPC linkXXXX.res is
            # itself a script and Windows binutils may misdetect duplicates.
            name = stage_runtime(cc, stage, lib, 'kvm_' + lib)
            crt_archives.append(stage/('lib' + name + '.a'))
        if args.with_dxgi:
            # The POSIX-thread MinGW C++ runtime can import libwinpthread-1.dll
            # EVEN with -static-libgcc -static-libstdc++. A complete standalone
            # build must link actual winpthreads implementation objects.
            # Prefer the archive from the selected SDK, NEVER a DLL import lib.
            static_pthreads = Path(run([cc, '-print-file-name=libwinpthread.a'], capture=True))
            if static_pthreads.is_file():
                name = stage_runtime(cc, stage, 'winpthread', 'kvm_winpthread')
                pthread_archive = stage / ('lib' + name + '.a')
                check_windows_archive(pthread_archive, objdump, cpu)
                assert_archive(pthread_archive, nm, ['pthread_create', 'pthread_join'])
                # Merge it into the same indexed .a as GCC/mingwex so the FPC
                # linker can resolve C++ <-> POSIX threads <-> C runtime cycles.
                crt_archives.append(pthread_archive)
            else:
                print('NOTE: libwinpthread.a is missing from the toolchain. '
                      'The MinGW win32 model usually does not need it; '
                      'the DXGI probe will reject any libwinpthread-1.dll dependency.', flush=True)
        merge_crt_archives(ar, stage/'libkvm_wincrt.a', crt_archives)
        turbo_links = ['{$LINKLIB kvm_wincrt}']
        # Never add libmingw32.a, and never request -static globally.
    write(stage/'kvm_turbojpeg_link.inc','\n'.join(turbo_links)+'\n')
    # A real native executable catches wrong CPU/CRT and missing static
    # dependencies before the Pascal build. It runs from a clean directory.
    import tempfile
    probe=stage/('probe_jpeg.exe' if is_windows(os_name) else 'probe_jpeg')
    native_link=['-static-libgcc'] if is_windows(os_name) else ['-lm']
    run([cc, *cflags, ROOT/'tests/test_static_turbojpeg.c', destination,
         *native_link, '-o', probe])
    audit_binary(probe, cpu, os_name, objdump)
    with tempfile.TemporaryDirectory(prefix='lazdesk-native-link-') as clean:
        clean_dir=Path(clean)
        isolated=clean_dir/probe.name
        shutil.copy2(probe,isolated)
        run([isolated], cwd=clean_dir,
            clean_windows_runtime=is_windows(os_name))
    if args.only != 'client':
        if os_name == 'linux':
            native_archive(cc,ar,stage/'libkvm_session.a',ROOT/'native/session/kvm_session_linux.c',cflags)
            assert_archive(stage/'libkvm_session.a',nm,['lazdesk_session_open_ex','lazdesk_session_poll'])
        elif os_name == 'darwin':
            native_archive(cc,ar,stage/'libkvm_sck.a',ROOT/'native/macos/kvm_sck.m',
                ['-O2','-fobjc-arc','-fblocks','-Wall','-Wextra','-Wno-unused-parameter',
                 '-arch','arm64' if cpu=='aarch64' else 'x86_64','-mmacosx-version-min=12.3'])
            assert_archive(stage/'libkvm_sck.a',nm,['kvm_sck_open','kvm_sck_session'])
        elif args.with_dxgi:
            cxx=select_c_tool('g++', selected(args.cxx, 'CXX'), args.toolchain_bin, cc, cpu=cpu)
            check_c_target(cxx,cpu,os_name)
            native_archive(cxx,ar,stage/'libkvm_dxgi.a',ROOT/'native/windows/kvm_dxgi.cpp',
                           ['-std=c++17','-O2','-Wall','-Wextra'])
            assert_archive(stage/'libkvm_dxgi.a',nm,['kvm_dxgi_open','kvm_dxgi_read'])
            # Do not reintroduce libmingw32.a through the optional DXGI path.
            # The already-staged wincrt GROUP resolves GCC/mingwex/msvcrt and
            # the FPC RTL remains the sole owner of the process startup/TLS.
            name=stage_runtime(cxx,stage,'stdc++','kvm_stdcpp')
            runtime_archives=[stage/('lib'+name+'.a')]
            # MinGW defines atexit() in its executable startup (crtexe.o).
            # FPC owns the Windows entry point/TLS, so linking that startup
            # would conflict with FPC; static libstdc++ still needs atexit.
            # Link a tiny C shim that forwards to the *system* CRT's
            # _crt_atexit, matching MinGW-w64 crtexe.c without its startup.
            native_archive(cc, ar, stage/'libkvm_fpc_atexit.a',
                           ROOT/'native/windows/kvm_fpc_atexit.c',
                           ['-std=c11', '-O2', '-Wall', '-Wextra'])
            assert_archive(stage/'libkvm_fpc_atexit.a', nm, ['atexit'])
            # The shim must appear after stdc++ and BEFORE the CRT imports.
            links=['{$LINKLIB '+name+'}', '{$LINKLIB kvm_fpc_atexit}',
                   '{$LINKLIB kvm_wincrt}']
            links += ['{$LINKLIB ' + lib + '}' for lib in ['d3d11','dxgi','dxguid','uuid','user32','gdi32','kernel32','advapi32']]
            write(stage/'kvm_dxgi_link.inc','\n'.join(links)+'\n')
            # Verify the SAME static archives as FPC: C++ runtime AND the
            # merged CRT (which includes real winpthreads objects when present).
            # Without the latter, GCC can silently pick libwinpthread.dll.a.
            probe=stage/'probe_dxgi.cpp'
            write(probe,'extern "C" int kvm_dxgi_abi();\nint main(){return kvm_dxgi_abi()!=3;}\n')
            run([cxx,'-static-libgcc','-static-libstdc++',probe,stage/'libkvm_dxgi.a',
                 '-Wl,--start-group',*runtime_archives,stage/'libkvm_wincrt.a',
                 '-Wl,--end-group',
                 '-ld3d11','-ldxgi','-ldxguid','-luuid','-luser32','-lgdi32','-o',stage/'probe_dxgi.exe'])
            audit_binary(stage/'probe_dxgi.exe', cpu, os_name, objdump)
            run([stage/'probe_dxgi.exe'])
            defines += ['KVM_STATIC_DXGI']
    if args.with_portal:
        modules='gio-2.0 gio-unix-2.0 libpipewire-0.3'
        native_archive(cc,ar,stage/'libkvm_portal.a',ROOT/'native/linux/kvm_portal.c',cflags+pkg(modules,'--cflags'))
        text,dirs=system_links(pkg(modules,'--libs'),extra=['c','pthread'])
        write(stage/'kvm_portal_link.inc',text); search+=dirs
        assert_archive(stage/'libkvm_portal.a',nm,['kvm_portal_abi','kvm_portal_open','kvm_portal_read'])
        defines+=['KVM_STATIC_PORTAL']
    if args.with_codec:
        modules='libavcodec libavutil libswscale'
        native_archive(cc,ar,stage/'libkvm_codec.a',ROOT/'native/codec/kvm_codec.c',cflags+pkg(modules,'--cflags'))
        text,dirs=system_links(pkg(modules,'--libs'),extra=['c','m'])
        write(stage/'kvm_codec_link.inc',text); search+=dirs
        assert_archive(stage/'libkvm_codec.a',nm,['lazdesk_codec_abi','lazdesk_encoder_open','lazdesk_decoder_open'])
        defines+=['KVM_STATIC_CODEC']
    features = feature_include(cpu, os_name, defines)
    write(stage/'kvm_standalone_features.inc',features)
    search=list(dict.fromkeys(search))
    projects=make_projects(target,search,os_name,fpc=fpc,linker_flags=linker_flags)
    output=ROOT/'dist'/target
    output.mkdir(parents=True,exist_ok=True)
    manifest={'target':target,'requested_arch':args.arch,'fpc':fpc,'cc':cc,
              'ar':ar,'nm':nm,'objdump':objdump,'features':defines,'base':'TurboJPEG static; system libraries dynamic',
              'source_turbojpeg_archive':str(jpeg),
              'archives':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in stage.glob('*.a')},
              'complete_applications_built':False}
    write(stage/'build-manifest.json',json.dumps(manifest,indent=2)+'\n')
    if args.prepare_only:
        print('Archives prepared; projects: '+', '.join(str(p) for p in projects))
        print('No Pascal applications built with --prepare-only.')
        return 0
    if not args.skip_smoke:
        units=stage/'test-units'; units.mkdir(exist_ok=True)
        executable=stage/('test_standalone_link.exe' if is_windows(os_name) else 'test_standalone_link')
        opts=[*fpc_target_flags(cpu, os_name),'-B','-O2','-dKVM_STANDALONE','-Fu'+str(ROOT/'shared'),'-Fu'+str(ROOT/'server'),
              '-Fu'+str(ROOT/'client'),'-Fi'+str(ROOT/'shared'),'-Fi'+str(stage),
              '-Fl'+str(stage),'-FU'+str(units),'-o'+str(executable)]
        # Skip the server-only session ABI check for a client-only preparation.
        if args.only=='client': opts+=['-dKVM_TEST_CLIENT_ONLY']
        if os_name=='darwin': opts+=['-WM12.3']
        if is_windows(os_name): opts+=linker_flags
        opts += ['-Fl' + path for path in search]
        run([fpc,*opts,ROOT/'tests/test_standalone_link.lpr'])
        audit_binary(executable, cpu, os_name, objdump)
        # Run the linked Pascal/native smoke test without MinGW on PATH too.
        # This detects DW2 runtime LoadLibrary dependencies that a PE import
        # table inspection cannot see.
        if is_windows(os_name):
            with tempfile.TemporaryDirectory(prefix='lazdesk-pascal-link-') as clean:
                isolated = Path(clean) / executable.name
                shutil.copy2(executable, isolated)
                run([isolated], cwd=Path(clean), clean_windows_runtime=True)
        else:
            run([executable])
    if mormot_package is not None:
        # Make the selected upstream package visible to Lazarus, then rebuild its
        # package explicitly before the applications. `--build-all` alone on
        # the application may use another previously registered mORMot2 PPU.
        print('Using mORMot2: '+str(mormot_package.resolve()), flush=True)
        register_lazarus_package_link(laz, mormot_package)
        run([laz,'--build-all','--compiler='+fpc,'--cpu='+cpu,'--os='+os_name,
             mormot_package])
    # Force rebuilding after feature changes; no stale standalone .ppu reuse.
    for role,app,project in zip(['server','client'],['LazDeskServer','LazDeskClient'],projects):
        if args.only not in ['both',role]: continue
        exe=output/(app+('.exe' if is_windows(os_name) else ''))
        exe.unlink(missing_ok=True)
        opts=['--build-all','--compiler='+fpc,'--cpu='+cpu,'--os='+os_name]
        if role=='client':
            widgetset=args.widgetset or ('cocoa' if os_name=='darwin' else None)
            if widgetset: opts+=['--widgetset='+widgetset]
        run([laz,*opts,project])
        if not exe.is_file(): raise BuildError('Executable not produced: '+str(exe))
        audit_binary(exe, cpu, os_name, objdump, output/(app+'-dependencies.txt'))
    manifest['complete_applications_built']=True
    manifest['built_roles']=args.only
    write(stage/'build-manifest.json',json.dumps(manifest,indent=2)+'\n')
    print('\nDone: executables in '+str(output))
    print('Copy only the required server OR client; retain third-party distribution notices.')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (BuildError, OSError) as exc:
        print('ERROR: '+str(exc), file=sys.stderr)
        sys.exit(2)

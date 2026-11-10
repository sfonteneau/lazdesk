#!/usr/bin/env python3
"""Compile/run actual Pascal P1/P2/P3 tests; never substitute Python models.

Use --arch x86 --standalone --toolchain-bin ... after standalone preparation.
A missing FPC/native profile is NOT RUN (exit 2). No compiler is downloaded.
"""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
ROOT = Path(__file__).resolve().parents[1]

def command(argv, cwd=ROOT):
    args = [str(a) for a in argv]
    print('+ ' + subprocess.list2cmdline(args), flush=True)
    env = os.environ.copy()
    env['LAZDESK_CLIENT_LOG'] = str(Path(cwd) / 'worker-test.log')
    subprocess.run(args, cwd=cwd, env=env, check=True)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--fpc', default='fpc')
    ap.add_argument('--arch', choices=['native', 'x86', 'x64'], default='native')
    ap.add_argument('--standalone', action='store_true')
    ap.add_argument('--toolchain-bin', type=Path)
    ap.add_argument('--bench-windows', action='store_true')
    a = ap.parse_args()
    compiler = shutil.which(a.fpc)
    if not compiler:
        print('NOT RUN: Free Pascal absent: ' + a.fpc, file=sys.stderr)
        return 2
    spec = importlib.util.spec_from_file_location('kvm_builder_for_tests', ROOT / 'build/build_standalone.py')
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)
    cpu, system = build.host_target(a.arch)
    build.check_fpc_target(compiler, cpu, system)
    windows = build.is_windows(system)
    opts = build.fpc_target_flags(cpu, system) + ['-B', '-O2', '-Cr', '-Co', '-gl']
    opts += ['-Fu' + str(ROOT / p) for p in ('shared', 'server', 'client', 'tests/fixtures')]
    opts += ['-Fi' + str(ROOT / 'shared')]
    manifest = None
    if a.standalone:
        stage = ROOT / 'native/static' / (cpu + '-' + system)
        if not (stage / 'kvm_standalone_features.inc').is_file() or not (stage / 'build-manifest.json').is_file():
            print('NOT RUN: prepare this standalone target first: ' + str(stage), file=sys.stderr)
            return 2
        manifest = json.loads((stage / 'build-manifest.json').read_text())
        if manifest['target'] != cpu + '-' + system:
            raise RuntimeError('Wrong standalone target')
        opts += ['-dKVM_STANDALONE', '-Fi' + str(stage), '-Fl' + str(stage)]
    if windows:
        bindir = a.toolchain_bin
        if bindir is None and manifest:
            bindir = Path(manifest['cc']).parent
        if bindir is None:
            print('NOT RUN: --toolchain-bin required on Windows', file=sys.stderr)
            return 2
        cc = build.select_c_tool('gcc', None, bindir, cpu=cpu)
        ld = build.select_c_tool('ld', None, bindir, cc, cpu=cpu)
        build.check_windows_linker(ld, cpu)
        opts += build.windows_linker_flags(cc, ld)
    if system == 'darwin':
        opts += ['-WM12.3']
    tests = ['test_perf_frame', 'test_perf_surface_pool', 'test_perf_flow',
             'test_p123_core', 'test_p123_worker', 'test_flow', 'test_pipeline_copy']
    if windows:
        tests += ['test_p123_win_present']
    elif a.bench_windows:
        raise RuntimeError('--bench-windows requires Windows')
    if a.bench_windows:
        tests += ['bench_p123_capture_win']
    with tempfile.TemporaryDirectory(prefix='lazdesk-p123-tests-') as tmp:
        tmp = Path(tmp)
        for name in tests:
            units = tmp / (name + '-units')
            units.mkdir()
            executable = tmp / (name + ('.exe' if windows else ''))
            command([compiler, *opts, '-FU' + str(units), '-o' + str(executable), ROOT / 'tests' / (name + '.lpr')])
            command([executable], cwd=tmp)
    print('PASS: actual Pascal suites executed; no network/FPS qualification implied.')
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print('FAIL: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)

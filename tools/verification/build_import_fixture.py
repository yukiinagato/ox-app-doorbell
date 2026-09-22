#!/usr/bin/env python3
"""Link frozen Web resources to the verified T29 production Core for import UI verification."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--core-build', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source, core, out = args.source.resolve(), args.core_build.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    fixture = root / 'tools/verification/config_import_fixture.cpp'
    frozen_fixture = out / fixture.name
    frozen_fixture.write_bytes(fixture.read_bytes())
    flags_path = core / 'CMakeFiles/doorbell_core.dir/flags.make'
    lines = flags_path.read_text().splitlines()
    flags = []
    for key in ['CXX_DEFINES = ', 'CXX_INCLUDES = ', 'CXX_FLAGS = ']:
        flags += shlex.split(next(line[len(key):] for line in lines if line.startswith(key)))
    generated = out / 'webui_assets.cpp'
    binary = out / 'config-import-fixture'
    commands = [
        ['python3', str(source / 'tools/embed_webui.py'), str(generated)],
        ['/usr/bin/c++', *flags, '-c', str(generated), '-o', str(out / 'webui_assets.o')],
        ['/usr/bin/c++', *flags, str(frozen_fixture), str(out / 'webui_assets.o'),
         str(core / 'libdoorbell_core.a'), str(core / 'libdb_third_party.a'),
         '-lpthread', '-o', str(binary)],
    ]
    record = {'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'frozen_web_root': str(source), 'core_build': str(core), 'commands': [],
              'inputs': {str(p): digest(p) for p in [fixture, flags_path,
                         core / 'libdoorbell_core.a', core / 'libdb_third_party.a']},
              'scope': 'Actual T29 HTTP/Node/SQLite with frozen Web resources; isolated in-memory mesh and SIP stub.'}
    for index, command in enumerate(commands):
        log = out / f'build-{index}.log'
        with log.open('w') as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                    cwd=source, timeout=180)
        record['commands'].append({'command': command, 'exit_code': result.returncode,
                                   'log': str(log), 'log_sha256': digest(log)})
        if result.returncode:
            break
    record['finished_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    if binary.exists():
        record['binary_sha256'] = digest(binary)
        record['generated_resources_sha256'] = digest(generated)
    (out / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
    return record['commands'][-1]['exit_code']


if __name__ == '__main__':
    raise SystemExit(main())

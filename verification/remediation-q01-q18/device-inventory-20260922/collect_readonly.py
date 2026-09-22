#!/usr/bin/env python3
"""Read existing test-device metadata without changing app or device state."""
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import tempfile
import urllib.error
import urllib.request

OUT = Path(__file__).resolve().parent
MEMORY = Path('/Users/ox/.claude/projects/-Users-ox-Documents-project-app-doorbell/memory')


def run(argv, env=None, timeout=20):
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        p = subprocess.run(argv, capture_output=True, env=env, timeout=timeout)
        return p.returncode, p.stdout, p.stderr.decode(errors='replace'), started
    except subprocess.TimeoutExpired:
        return 124, b'', 'Command timed out', started


def stored_environment():
    for name in ('project-ipad1-update-runbook.md', 'project-device-role-rotation.md',
                 'project-worktree-build-prereqs.md'):
        for match in re.finditer(r'\bSSHPASS\s*=\s*[\'\"]?([^\'\"\s`]+)',
                                 (MEMORY / name).read_text()):
            value = match.group(1)
            if not any(c in value for c in '<>{}$'):
                env = dict(os.environ)
                env['SSHPASS'] = value
                return env
    return None


def read_ssh(name, address, port, bundle):
    if name == 'ipad-air1':
        ssh = ['ssh', '-o', 'ConnectTimeout=5', '-o', 'ConnectionAttempts=1',
               'doorbell-ipad-air1']
        env = None
        auth = 'Existing public-key alias; strict saved host identity'
    else:
        env = stored_environment()
        if env is None:
            return {'device': name, 'error': 'Recorded credential unavailable'}
        ssh = ['sshpass', '-e', 'ssh', '-o', 'BatchMode=no', '-o', 'ConnectTimeout=5',
               '-o', 'ConnectionAttempts=1', '-o', 'StrictHostKeyChecking=yes',
               '-o', 'UserKnownHostsFile=/Users/ox/.ssh/known_hosts',
               '-o', 'HostKeyAlgorithms=+ssh-rsa', '-o', 'PubkeyAuthentication=no',
               '-o', 'PreferredAuthentications=password,keyboard-interactive',
               '-o', 'NumberOfPasswordPrompts=1', '-p', str(port), 'root@' + address]
        auth = 'Recorded credential supplied only in child environment; strict saved host identity'
    record = {'device': name, 'address': address, 'ssh_port': port, 'authentication': auth,
              'observations': []}

    def observe(label, command, parse=None):
        code, data, error, started = run(ssh + [command], env)
        entry = {'label': label, 'remote_command': command, 'started_at': started,
                 'exit_code': code}
        if code == 0:
            try:
                entry['value'] = parse(data) if parse else data.decode(errors='replace').strip()
            except Exception as e:
                entry['parse_error'] = type(e).__name__
        elif error:
            entry['error'] = error.strip()
        record['observations'].append(entry)

    observe('kernel_machine_and_cpu', 'uname -m; uname -r; sysctl -n hw.cputype hw.cpusubtype')
    observe('os_version', 'cat /System/Library/CoreServices/SystemVersion.plist',
            lambda b: {k: v for k, v in plistlib.loads(b).items()
                       if k in ('ProductName', 'ProductVersion', 'ProductBuildVersion')})
    observe('installed_app_version', 'cat ' + bundle + '/Info.plist',
            lambda b: {k: v for k, v in plistlib.loads(b).items()
                       if k in ('CFBundleIdentifier', 'CFBundleShortVersionString',
                                'CFBundleVersion', 'CFBundleExecutable', 'MinimumOSVersion')})
    observe('doorbell_launch_jobs', 'launchctl list',
            lambda b: [line for line in b.decode(errors='replace').splitlines()
                       if 'doorbell' in line.lower()])
    if name == 'ipad-air1':
        observe('doorbell_process', 'ps -A -o pid,comm',
                lambda b: [line for line in b.decode(errors='replace').splitlines()
                           if 'doorbell' in line.lower()])
    return record


def http_probe(label, address):
    url = 'http://' + address + ':47180/api/status'
    result = {'device': label, 'url': url, 'method': 'GET',
              'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            data = response.read(1024 * 1024)
            result.update(http_status=response.status, content_type=response.headers.get('Content-Type'))
            try:
                obj = json.loads(data)
                allowed = ('version', 'core_version', 'app_version', 'build', 'build_number',
                           'role', 'platform', 'os_version', 'architecture')
                result['selected_status'] = {k: obj[k] for k in allowed
                                             if isinstance(obj.get(k), (str, int, bool))}
                for key in ('self', 'node', 'runtime'):
                    if isinstance(obj.get(key), dict):
                        result['selected_status'][key] = {
                            k: obj[key][k] for k in allowed
                            if isinstance(obj[key].get(k), (str, int, bool))}
            except (ValueError, TypeError):
                result['body_kind'] = 'Non-JSON response; body not retained'
    except urllib.error.HTTPError as e:
        result['http_status'] = e.code
        result['interpretation'] = 'HTTP server answered; authenticated application state not read'
    except Exception as e:
        result['error'] = str(e)
    return result


def tcp_probe(address, port):
    result = {'address': address, 'port': port,
              'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        with socket.create_connection((address, port), timeout=4):
            result['connected'] = True
    except OSError as e:
        result.update(connected=False, error=str(e))
    return result


def devicectl_json(args):
    with tempfile.TemporaryDirectory(prefix='doorbell-readonly-device-info-') as temp:
        path = Path(temp) / 'metadata.json'
        argv = ['xcrun', 'devicectl'] + args + ['--timeout', '15', '--json-output', str(path)]
        code, _, error, started = run(argv, timeout=20)
        obj = json.loads(path.read_text()) if path.exists() else {}
        return {'command': ['xcrun', 'devicectl'] + args, 'exit_code': code,
                'started_at': started, 'error': error.strip() if code else ''}, obj


def dicts(obj):
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from dicts(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from dicts(value)


def iphone_metadata():
    ident = '54DB00FE-62A0-5739-9679-B7C513DFCEC4'
    result = {'device': 'iphone17', 'coredevice_id': ident}
    for kind in ('details', 'apps', 'processes'):
        args = ['device', 'info', kind, '--device', ident]
        if kind == 'apps':
            args += ['--bundle-id', 'jp.ox.doorbell']
        record, obj = devicectl_json(args)
        selected = []
        for item in dicts(obj.get('result', {})):
            if kind == 'details' and 'hardwareProperties' in item:
                selected.append({
                    'hardware': {k: item['hardwareProperties'][k]
                                 for k in ('cpuType', 'productType', 'reality', 'platform')
                                 if k in item['hardwareProperties']},
                    'device': {k: item.get('deviceProperties', {}).get(k)
                               for k in ('osVersionNumber', 'osBuildUpdate', 'bootState',
                                         'developerModeStatus')},
                    'connection': {k: item.get('connectionProperties', {}).get(k)
                                   for k in ('transportType', 'pairingState', 'tunnelState')}})
            if kind == 'apps' and item.get('bundleIdentifier') == 'jp.ox.doorbell':
                selected.append({k: item[k] for k in ('name', 'bundleIdentifier', 'version',
                                                     'bundleVersion', 'path') if k in item})
            if kind == 'processes' and 'executable' in item and 'Doorbell' in str(item['executable']):
                selected.append({k: item[k] for k in ('processIdentifier', 'executable') if k in item})
        record['selected_metadata'] = selected
        result[kind] = record
    return result


jobs = {
    'ipad_air1': lambda: read_ssh('ipad-air1', '10.10.38.199', 44,
        '/private/var/containers/Bundle/Application/64FD671A-D11A-464E-8D6B-C2A35A9F31F0/Doorbell.app'),
    'ipad1': lambda: read_ssh('ipad1', '10.10.38.147', 22, '/Applications/Doorbell.app'),
    'iphone17': iphone_metadata,
    'http_status': lambda: [http_probe(name, ip) for name, ip in (
        ('ipad-air1', '10.10.38.199'), ('ipad1', '10.10.38.147'),
        ('ipad-mini3', '10.10.38.79'), ('android-moto-recorded-address', '10.10.39.174'),
        ('windows-recorded-address', '10.10.38.43'), ('iphone17-recorded-address', '10.10.38.80'))],
    'known_endpoint_tcp': lambda: [tcp_probe(ip, port) for ip, port in (
        ('10.10.38.79', 44), ('10.10.38.79', 22), ('10.10.38.43', 3389),
        ('10.10.38.43', 445))],
}
result = {'schema_version': 1, 'date': '2026-09-22', 'mode': 'read_only',
          'restrictions': ['No installation, restart, configuration or app-state mutation',
                           'No lock/SOS/call action, backups or network-range scan',
                           'Existing pinned host identities retained',
                           'No credential values, private key or boot contents retained']}
with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs)) as executor:
    futures = {name: executor.submit(job) for name, job in jobs.items()}
    for name, future in futures.items():
        try:
            result[name] = future.result()
        except Exception as e:
            result[name] = {'error': type(e).__name__}
for name, command in [('adb', ['adb', 'devices', '-l']), ('usb_ios', ['idevice_id', '-l'])]:
    code, stdout, error, started = run(command)
    result[name] = {'command': command, 'exit_code': code, 'started_at': started,
                    'output': stdout.decode(errors='replace').strip(), 'error': error.strip()}
result['source_documents'] = {
    str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (
        Path('docs/en/test-devices.md'), Path('/Users/ox/.codex/memories/doorbell-device-access.md'),
        MEMORY / 'MEMORY.md', MEMORY / 'project-ipad1-update-runbook.md',
        MEMORY / 'project-mini3-swift-shell-workflow.md', MEMORY / 'project-device-role-rotation.md',
        MEMORY / 'project-iphone17-free-signing-runbook.md', MEMORY / 'project-worktree-build-prereqs.md')}
target = OUT / 'inventory.json'
target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print('Read-only device inventory saved:', target)
print('Collected:', ', '.join(jobs), 'plus adb and USB iOS lists')

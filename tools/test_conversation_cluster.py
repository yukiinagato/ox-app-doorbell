#!/usr/bin/env python3
"""Exercise production authority, mesh commands and real SIP with isolated local test identities."""
import json
from pathlib import Path
import queue
import threading
import shutil
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path('/tmp/doorbell-conversation-cluster-v1')
MARKER = WORK / '.owned-by-conversation-test'
if WORK.exists():
    if not MARKER.exists():
        raise SystemExit('Refusing to reuse an unowned test directory')
    shutil.rmtree(WORK)
WORK.mkdir(mode=0o700)
MARKER.touch()
for port, kind in [(39171, socket.SOCK_STREAM), (39172, socket.SOCK_STREAM),
                   (39173, socket.SOCK_STREAM), (39174, socket.SOCK_STREAM), (47190, socket.SOCK_DGRAM)]:
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(('127.0.0.1', port))

class Peer:
    def __init__(self, name, port, station=False):
        self.name, self.port, self.station = name, port, station
        self.process = None
        self.start()
    def start(self):
        backend = 'build/conversation-host-pjsip' if self.station else 'build'
        directory = WORK / self.name
        directory.mkdir(exist_ok=True)
        self.log = (WORK / (self.name + '.log')).open('a')
        self.process = subprocess.Popen([str(ROOT / backend / 'doorbell_conversation_node_probe'),
            str(directory), 'door_station' if self.station else 'indoor_panel',
            'front' if self.station else '', str(self.port), '39172' if self.station else '39171'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1)
        self.responses = queue.Queue()
        def consume():
            for line in self.process.stdout:
                if line.startswith('RESULT '):
                    self.responses.put(json.loads(line[7:]))
                else:
                    self.log.write(line)
            self.responses.put(None)
        self.reader = threading.Thread(target=consume, daemon=True)
        self.reader.start()
        try:
            assert self.read(12).get('ready') is True
        except BaseException:
            self.process.kill(); self.process.wait(timeout=3)
            self.reader.join(timeout=2)
            self.log.close()
            raise
    def read(self, timeout=8):
        try:
            result = self.responses.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError(self.name + ' response timeout; inspect ' + str(WORK))
        if result is None:
            raise AssertionError(self.name + ' exited; inspect ' + str(WORK))
        return result
    def send(self, body):
        self.process.stdin.write(json.dumps(body) + '\n')
        self.process.stdin.flush()
        return self.read()
    def status(self):
        return self.send({'op': 'status'})
    def stop(self):
        if self.process and self.process.poll() is None:
            try:
                self.send({'op': 'exit'})
                self.process.wait(timeout=8)
            except Exception:
                self.process.kill()
                self.process.wait(timeout=3)
        self.reader.join(timeout=2)
        self.log.close()

def wait(predicate, label, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError('Timed out: ' + label + '; inspect ' + str(WORK))

peers = []
try:
    station = Peer('station', 39171, True); peers.append(station)
    living = Peer('living', 39172); peers.append(living)
    kitchen = Peer('kitchen', 39173); peers.append(kitchen)
    bedroom = Peer('bedroom', 39174); peers.append(bedroom)
    wait(lambda: len([p for p in station.status().get('peers', []) if p.get('status') == 'alive']) >= 3,
         'four-node membership')
    living_id = living.status()['node']['id']
    kitchen_id = kitchen.status()['node']['id']
    bedroom_id = bedroom.status()['node']['id']
    call_id = station.send({'op': 'press'})['call_id']
    assert call_id
    def call(peer=station):
        return next((c for c in peer.status().get('active_calls', []) if c['call_id'] == call_id), None)
    def room():
        return (call() or {}).get('conversation', {})
    def member(peer_id):
        return next((m for m in room().get('participants', []) if m['device'] == peer_id), {})
    def act(peer, action, version=None):
        wait(lambda: (call(peer) or {}).get('conversation_supported'), 'authority route available to ' + peer.name)
        body = {'op': 'action', 'door': 'front', 'call_id': call_id, 'stage_revision': 0,
                'action': action, 'expected_version': room().get('version', 0) if version is None else version}
        response = peer.send(body)
        assert response.get('ok'), response
        return response
    wait(lambda: (call(living) or {}).get('conversation_supported'), 'measured host capability')
    act(living, 'respond')
    wait(lambda: member(living_id).get('state') == 'waiting', 'response queue visible at station')
    assert call()['state'] == 'ringing'
    act(living, 'answer')
    wait(lambda: member(living_id).get('state') == 'connected', 'first real SIP leg connected')
    assert call()['state'] == 'in_call'
    act(kitchen, 'join')
    wait(lambda: member(kitchen_id).get('state') == 'connected', 'second resident joined')
    assert room()['owner'] == living_id
    act(living, 'hold')
    wait(lambda: member(living_id).get('state') == 'held', 'participant held without ending the other participant')
    assert member(kitchen_id)['state'] == 'connected'
    act(living, 'resume')
    wait(lambda: member(living_id).get('state') == 'connected', 'same-dialog resume')
    old_leg = member(kitchen_id)['leg']
    act(kitchen, 'takeover')
    wait(lambda: room().get('owner') == kitchen_id and member(kitchen_id).get('state') == 'connected' and
         len(room().get('participants', [])) == 1, 'joined resident takes over with a new generation')
    assert member(kitchen_id)['leg'] != old_leg
    observed = room()['version']
    act(living, 'takeover', observed)
    act(bedroom, 'takeover', observed)
    wait(lambda: room().get('owner') in (living_id, bedroom_id) and
         room().get('phase') == 'connected', 'one winner of simultaneous takeover requests')
    assert len(room()['participants']) == 1
    winner = living if room()['owner'] == living_id else bedroom
    before = room()['version']
    loser = bedroom if winner is living else living
    act(loser, 'leave', before)
    time.sleep(.5)
    assert room()['version'] == before
    act(winner, 'leave')
    wait(lambda: call() is None, 'last participant departure ends only this visitor call')
    print('conversation cluster: response/answer/join/hold/resume/takeover/conflict/departure PASS', flush=True)
    call_id = station.send({'op': 'press'})['call_id']
    wait(lambda: (call(kitchen) or {}).get('conversation_supported'), 'second visitor admission')
    act(kitchen, 'answer')
    wait(lambda: member(kitchen_id).get('state') == 'connected', 'second call connected')
    station_id = station.status()['node']['id']
    station.stop()
    station.start()
    assert station.status()['node']['id'] == station_id
    wait(lambda: member(kitchen_id).get('state') == 'held', 'authority restart fences old media')
    time.sleep(.4)
    assert member(kitchen_id)['state'] == 'held'
    assert member(kitchen_id)['established'] is False
    act(kitchen, 'resume')
    wait(lambda: member(kitchen_id).get('state') == 'connected', 'explicit resume after authority restart')
    old_generation = member(kitchen_id)['leg']
    kitchen.process.kill(); kitchen.process.wait(timeout=3)
    kitchen.reader.join(timeout=2); kitchen.log.close()
    kitchen.start()
    assert kitchen.status()['node']['id'] == kitchen_id
    wait(lambda: (call(kitchen) or {}).get('conversation', {}).get('owner') == kitchen_id,
         'resident restart reconciles its exact membership')
    assert (call(kitchen) or {}).get('conversation_local_media') is False
    act(kitchen, 'resume')
    wait(lambda: member(kitchen_id).get('state') == 'connected' and member(kitchen_id).get('leg') != old_generation,
         'resident reconnect rotates its old SIP generation')
    act(kitchen, 'leave')
    wait(lambda: call() is None, 'recovered participant leaves normally')
    print('conversation cluster: authority restart/resident restart/explicit recovery PASS', flush=True)

finally:
    for peer in reversed(peers): peer.stop()

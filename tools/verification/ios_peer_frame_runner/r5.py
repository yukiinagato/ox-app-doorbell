#!/usr/bin/env python3
"""Replay the unchanged T15 UIKit runner against the T35 r5 controller delta."""
import pathlib,sys
root=pathlib.Path.cwd();mode=sys.argv[1]
evidence=root/'verification/remediation-q01-q18/T35-ios-modern/evidence/peer-frame-r5';evidence.mkdir(exist_ok=True)
if mode=='prepare':
 code=(root/'tools/verification/ios_peer_frame_runner/prepare.py').read_text()
 code=code.replace('source-r4','source-r5').replace('remediation-t15-device-uikit','remediation-t15-r5-device-uikit').replace("CFBundleVersion='2'","CFBundleVersion='3'")
elif mode=='build':
 sys.argv=[sys.argv[0],'candidate']
 code=(root/'tools/verification/ios_visitor_runner/build.py').read_text()
 code=code.replace("r/('build/remediation-t35-modern-device-'+lane)","r/'build/remediation-t15-r5-device-uikit'").replace("r/'verification/remediation-q01-q18/T35-ios-modern/evidence/device-uikit'","r/'verification/remediation-q01-q18/T35-ios-modern/evidence/peer-frame-r5'")
 code=code.replace('jp.ox.doorbell.t35modernuitest','jp.ox.doorbell.t15uitest').replace('tools/verification/ios_visitor_runner/register.m','tools/verification/ios_peer_frame_runner/register.m')
elif mode=='device':
 sys.argv=[sys.argv[0]]+sys.argv[2:]
 code=(root/'tools/verification/ios_peer_frame_runner/device.py').read_text().replace('build/remediation-t15-device-uikit','build/remediation-t15-r5-device-uikit').replace('verification/remediation-q01-q18/T15/evidence/device-uikit','verification/remediation-q01-q18/T35-ios-modern/evidence/peer-frame-r5')
else:raise SystemExit('Expected prepare, build or device ACTION')
exec(compile(code,__file__+':'+mode,'exec'))

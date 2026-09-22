#!/usr/bin/env python3
"""Prepare an isolated app entry while preserving the reviewed media production sources."""
import hashlib, json, pathlib, plistlib, shutil, subprocess, sys
r=pathlib.Path.cwd(); base=r/'build/remediation-t35-ios-modern-r1-20260923/source-r4'; lane=sys.argv[1] if len(sys.argv)>1 else 'candidate'; assert lane in ['baseline','candidate']; base=r/('build/remediation-t35-ios-modern-r1-20260923/source-r4' if lane=='baseline' else 'build/remediation-t35-ios-modern-r1-20260923/source-r5'); out=r/('build/remediation-t35-modern-device-'+lane); src=out/'source'; out.mkdir(exist_ok=True)
if not src.exists(): subprocess.run(['cp','-cR',str(base),str(src)],check=True)
source_manifest=r/('verification/remediation-q01-q18/T35-ios-modern/source-r4.json' if lane=='baseline' else 'verification/remediation-q01-q18/T35-ios-modern/source-r5.json'); m=json.loads(source_manifest.read_text()); sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert all(sha(base/p)==h for p,h in m['files'].items())
assert sha(r/'verification/remediation-q01-q18/T15/evidence/production-diff.patch')=='dd34191170651e9fca4753925a6d6cb43fcd8dbf8dee9774538acf2d19b41b90'
runner=r/'tools/verification/ios_visitor_runner/Runner.swift'
if lane=='candidate':
 for name in ['ios/Doorbell/MainViewController.swift','ios/DoorbellTests/VisitorScreenLayoutTests.swift']:shutil.copy2(base/name,src/name)
if lane=='baseline':
 baseline=json.loads((r/'verification/remediation-q01-q18/T35-ios-modern/evidence/baseline-source.json').read_text())
 for item in baseline['inputs']:
  if item['path'] in ['ios/Doorbell/MainViewController.swift','ios/Doorbell/VisitorScreenView.swift','ios/Doorbell/SosSlideControl.swift','ios/Doorbell/IOSAvailability.swift']:
   original=pathlib.Path(item['retained_path']); assert sha(original)==item['sha256']; shutil.copy2(original,src/item['path'])
a=src/'ios/Doorbell/AppDelegate.swift'; a.write_text((base/'ios/Doorbell/AppDelegate.swift').read_text().replace('@UIApplicationMain\n','')+'\n'+runner.read_text())
p=src/'ios/Doorbell.xcodeproj/project.pbxproj'; s=(base/'ios/Doorbell.xcodeproj/project.pbxproj').read_text();s=s.replace('PRODUCT_BUNDLE_IDENTIFIER = jp.ox.doorbell;','PRODUCT_BUNDLE_IDENTIFIER = jp.ox.doorbell.t35modernuitest;');s=s.replace('shellScript = "exec \\"$SRCROOT/scripts/build_core.sh\\"\\n";', 'shellScript = "exit 0\\n";')
# Preserve the already-built, manifest-verified native archive from the exact frozen Core.
s=s.replace('exec \\"$SRCROOT/scripts/build_core.sh\\"\\n','exit 0\\n')
p.write_text(s)
info=src/'ios/Doorbell/Info.plist';d=plistlib.loads((base/'ios/Doorbell/Info.plist').read_bytes());d.update(CFBundleShortVersionString='1.0.0',CFBundleVersion=('1' if lane=='baseline' else '6'),CFBundleDisplayName='T35 UIKit',T35SourceManifest=sha(source_manifest));d['CFBundleURLTypes']=[{'CFBundleURLSchemes':['doorbell-t35-modern-test']}];info.write_bytes(plistlib.dumps(d))
archive=src/'ios/build/core/iphoneos/arm64/min-9.0/libdoorbell_all.a';native=src/'ios/build/core/iphoneos/arm64/min-9.0/artifact-manifest.json';assert sha(archive)==json.loads(native.read_text())['archive_sha256']
owned=['ios/Doorbell/CoreBridge.swift','ios/Doorbell/MainViewController.swift','ios/DoorbellTests/CoreBridgeLifecycleTests.swift'];assert lane=='baseline' or all((src/p).read_bytes()==(base/p).read_bytes() for p in owned)
meta={'lane':lane,'base_manifest':str(source_manifest),'base_manifest_sha256':sha(source_manifest),'source_root':str(src),'production_inputs':{p:sha(src/p) for p in owned+['ios/Doorbell/VisitorScreenView.swift','ios/Doorbell/SosSlideControl.swift','ios/Doorbell/IOSAvailability.swift']},'test_entry':{str(runner):sha(runner)},'build_adapters':{str(p.relative_to(src)):sha(p) for p in [a,p,info]},'native_archive':str(archive),'native_archive_sha256':sha(archive),'native_manifest':str(native),'native_manifest_sha256':sha(native),'scope':'Only UIApplication entry/bundle identity/native archive build adapters; baseline overlays exact four preserved pre-T35 UI files, candidate preserves exact r4 production files.'}
(out/'source-manifest.json').write_text(json.dumps(meta,indent=2)+'\n');print(src)

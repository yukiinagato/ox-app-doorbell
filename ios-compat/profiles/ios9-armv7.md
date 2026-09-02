# iOS 9 armv7 compatibility release profile

This profile compiles the shared Objective-C sources in `ios-kiosk/src`; it
does not own another UI source tree. It fixes the release dimensions to
`iphoneos`, minimum iOS 9.0, armv7, real PJSIP, and either `stock` or
`jailbreak` signing. Each dimension, plus the iPhoneOS SDK settings hash, is
part of the build/cache/artifact key.

The formal lane accepts only a locally licensed Xcode 7 installation whose
selected device SDK reports iPhoneOS 9.x. Setting
`DB_IOS9_SDK_LICENSE_ATTESTED=1` is a human attestation, not a license bypass.
A current Xcode that warns iOS 9 is outside its supported deployment range is
not an acceptable substitute and the preflight rejects it. Apple SDKs,
provisioning profiles, certificates, and built PJSIP archives are never
committed.

PJSIP must already exist at
`core/third_party/pjsip/ios/iphoneos/armv7/min-9.0`. Its manifest must bind the
Xcode 7/iPhoneOS 9 toolchain, PJSIP 2.15.1 source, armv7-only archives, and a
9.0 Mach-O minimum. Preflight and post-link checks require the UAC
`pjsua_call_make_call` symbol and UAS `pjsua_call_answer` symbol. MiniSIP and
the Core SIP stub are rejected.

The shell selects the public VideoToolbox adapter at compile time. Its formal
binary imports `VTDecompressionSessionCreate` and
`VTDecompressionSessionDecodeFrame` directly and must not import `dlopen` or
`dlsym`. Both iPhone and iPad device families are declared. The shared layout
contract treats widths below 500 points as compact and has a deterministic
host test for classic phone and tablet widths.

## Commands

An untrusted CI runner can run the profile, source-sharing, layout, packaging,
and fail-closed unit tests without any Apple signing material:

```sh
ios-compat/scripts/build_ios9_armv7.sh --static-only
```

This is the standalone workflow entry; the shared workflow can call exactly
that command after checkout. It deliberately does not contact a signing
runner.

On a commissioned machine, set the licensed toolchain and signing inputs, then
run a non-mutating preflight:

```sh
DB_IOS9_SDK_LICENSE_ATTESTED=1 \
DB_IOS9_DEVELOPER_DIR=/Applications/Xcode-7.3.1.app/Contents/Developer \
DB_IOS9_SIGNING_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567 \
DB_IOS9_PROVISIONING_PROFILE=/secure/path/Doorbell.mobileprovision \
ios-compat/scripts/build_ios9_armv7.sh --signing stock --preflight-only
```

Remove `--preflight-only` to produce a stock-signed IPA. Use
`--signing jailbreak` on a separately commissioned machine with `ldid` to
produce a jailbreak DEB. The two modes have different cache and artifact
directories. Neither package embeds `boot.json`, credentials, private keys, or
credential-bearing URLs. Formal packaging also refuses a dirty source tree.

The release manifest records numeric app/build versions, source revision and
hash, Core/PJSIP hashes, SDK/toolchain evidence, armv7 and minimum-OS checks,
bundle/package hashes, and the signing identity/profile evidence or `ldid`
evidence. It contains no private key or provisioning password.

## Hardware release gates

Host and link checks are not hardware certification. Release evidence still
requires stock iOS 9 armv7 iPhone and iPad runs where applicable: cold launch,
compact and regular layouts, incoming and outgoing PJSIP calls, public
VideoToolbox playback, background/foreground transitions, memory pressure,
crash/OOM recovery, pairing persistence, stock install/upgrade/rollback, and a
separate jailbreak package install/rollback. The exact provisioning profile,
device identifiers, helper mode, and observed OS build belong in the private
release record.

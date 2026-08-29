# iPad1 (A1219, iOS 5.1.1, armv7) 門铃ノード殻の素の clang ビルド。
# Xcode 26 の xcodebuild は armv7 不可 → clang を直接叩いて .app を組む。
# 検証上限: コンパイル+リンク成功 + lipo(armv7) + otool(健全性)。実機 UI 実走は不可。
#
# 使い方:
#   make            # コンパイル → リンク → Doorbell.app 組立 → ldid 伪签
#   make verify     # lipo / otool / 未解決記号チェック
#   make clean

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
SRC_DIR   := $(ROOT)/ios-legacy/Doorbell
MINISIP   := $(ROOT)/ios-legacy/mini_sip
QR        := $(ROOT)/ios-legacy/qr
CORE_INC  := $(ROOT)/core/include
LIB_DIR   := $(ROOT)/ios-legacy/lib
TC_LIB    := $(ROOT)/tools/toolchain/ios5-armv7/lib
SDK       := $(ROOT)/tools/sdk/iPhoneOS7.1.sdk
BUILD     := $(ROOT)/ios-legacy/build
OBJ       := $(BUILD)/obj
APP       := $(BUILD)/Doorbell.app

CLANG     := $(shell xcrun -f clang)
CLANG_RT  := $(shell xcrun clang -print-resource-dir)/lib/darwin/libclang_rt.ios.a
LDID      := $(shell command -v ldid 2>/dev/null || echo /opt/homebrew/bin/ldid)

ARCH      := -arch armv7
MINVER    := -miphoneos-version-min=5.1
SYSROOT   := -isysroot $(SDK)

# ObjC は MRC (libarclite が現代 Xcode に無く ARC 不可)。
CFLAGS    := $(ARCH) $(MINVER) $(SYSROOT) -Wall -O2 -I$(MINISIP) -I$(CORE_INC)
OBJCFLAGS := $(ARCH) $(MINVER) $(SYSROOT) -Wall -O2 -fno-objc-arc -I$(SRC_DIR) -I$(CORE_INC) -I$(MINISIP) -I$(QR)

FRAMEWORKS := -framework Foundation -framework UIKit -framework CoreGraphics \
              -framework QuartzCore -framework CFNetwork -framework AudioToolbox \
              -framework CoreAudio -framework AVFoundation -framework Security \
              -framework CoreFoundation -framework SystemConfiguration
# 静的 C++ ランタイム (順序: c++ → c++abi → unwind → builtins)。libdoorbell_all.a が要求。
RTLIBS := $(TC_LIB)/libc++.a $(TC_LIB)/libc++abi.a $(TC_LIB)/libunwind.a $(CLANG_RT)

OBJC_SRCS := $(wildcard $(SRC_DIR)/*.m)
C_SRCS    := $(MINISIP)/minisip.c $(MINISIP)/sip.c $(MINISIP)/sdp.c \
             $(MINISIP)/rtp.c $(MINISIP)/g711.c
QR_SRCS   := $(QR)/qrcodegen.c

OBJC_OBJS := $(patsubst $(SRC_DIR)/%.m,$(OBJ)/%.o,$(OBJC_SRCS))
C_OBJS    := $(patsubst $(MINISIP)/%.c,$(OBJ)/minisip_%.o,$(C_SRCS))
QR_OBJS   := $(patsubst $(QR)/%.c,$(OBJ)/qr_%.o,$(QR_SRCS))
ALL_OBJS  := $(OBJC_OBJS) $(C_OBJS) $(QR_OBJS)

EXE := $(APP)/Doorbell

.PHONY: all app verify clean

all: app

$(OBJ):
	@mkdir -p $(OBJ)

$(OBJ)/%.o: $(SRC_DIR)/%.m | $(OBJ)
	$(CLANG) $(OBJCFLAGS) -c $< -o $@

$(OBJ)/minisip_%.o: $(MINISIP)/%.c | $(OBJ)
	$(CLANG) $(CFLAGS) -c $< -o $@

$(OBJ)/qr_%.o: $(QR)/%.c | $(OBJ)
	$(CLANG) $(CFLAGS) -c $< -o $@

# libdoorbell_all.a を依存に含める — core 再ビルド時に app を確実に再リンクする
# (これが無いと .m 未変更時に core 変更が app に入らない)。
$(EXE): $(ALL_OBJS) $(LIB_DIR)/libdoorbell_all.a
	@mkdir -p $(APP)
	$(CLANG) $(ARCH) $(MINVER) $(SYSROOT) -o $@ \
	  $(ALL_OBJS) $(LIB_DIR)/libdoorbell_all.a $(RTLIBS) $(FRAMEWORKS)

app: $(EXE)
	@cp $(SRC_DIR)/Info.plist $(APP)/Info.plist
	@cp $(SRC_DIR)/Resources/*.png $(APP)/ 2>/dev/null || true
	@cp $(ROOT)/assets/audio/*.mp3 $(APP)/
	@$(LDID) -S $(EXE)
	@echo "ok: $(APP)"

verify: app
	@echo "-- lipo -info --"; lipo -info $(EXE)
	@echo "-- otool -L (dylib 依存: libSystem/frameworks のみ = libc++ 静的) --"; otool -L $(EXE)
	@echo "-- otool -l LC_VERSION_MIN_IPHONEOS --"; \
	  otool -l $(EXE) | grep -A3 LC_VERSION_MIN_IPHONEOS | head -8
	@echo "-- 未解決記号 (0 であること) --"; \
	  U=$$(nm -u $(EXE) 2>/dev/null | grep -v '^ *U _OBJC_' | grep -v dyld_stub_binder | grep '^ *U ' | wc -l); \
	  echo "   未定義 (dynamic import 除く): $$U 行 (framework/libSystem 記号は動的解決 = 正常)"

clean:
	rm -rf $(BUILD)

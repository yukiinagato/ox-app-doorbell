# iPad1 (A1219, iOS 5.1.1, armv7) kiosk 殻 — ios-kiosk 重写版 (ARC)。
# ios-legacy と同一ツールチェーンだが、ObjC 層は ARC で書き直している
# (-fobjc-arc は min iOS 5.1 で使用可 — 必要な runtime 記号は iOS 5.0+ に存在。
#  現代 clang は deployment target を見て objc_alloc (iOS 8+) を出さない)。
# 検証上限: コンパイル+リンク成功 + lipo(armv7) + otool(健全性)。
#
# 使い方:
#   make            # コンパイル → リンク → Doorbell.app 組立 → ldid 伪签
#   make verify     # lipo / otool / 未解決記号チェック
#   make clean

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
KIOSK     := $(ROOT)/ios-kiosk
SRC_DIR   := $(KIOSK)/src
MINISIP   := $(KIOSK)/mini_sip
QR        := $(KIOSK)/qr
CORE_INC  := $(ROOT)/core/include
LIB_DIR   := $(KIOSK)/lib
TC_LIB    := $(ROOT)/tools/toolchain/ios5-armv7/lib
SDK       := $(ROOT)/tools/sdk/iPhoneOS7.1.sdk
BUILD     := $(KIOSK)/build
OBJ       := $(BUILD)/obj
APP       := $(BUILD)/Doorbell.app

CLANG     := $(shell xcrun -f clang)
CXX       := $(shell xcrun -f clang++)
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path)
CLANG_RT  := $(shell xcrun clang -print-resource-dir)/lib/darwin/libclang_rt.ios.a
LDID      := $(shell command -v ldid 2>/dev/null || echo /opt/homebrew/bin/ldid)

ARCH      := -arch armv7
MINVER    := -miphoneos-version-min=5.1
SYSROOT   := -isysroot $(SDK)

# ObjC は ARC (iOS 5.1 target で正式サポート)。
OBJCFLAGS := $(ARCH) $(MINVER) $(SYSROOT) -Wall -O2 -fobjc-arc \
             -I$(SRC_DIR) -I$(SRC_DIR)/Support -I$(SRC_DIR)/Core -I$(SRC_DIR)/Net \
             -I$(SRC_DIR)/Media -I$(SRC_DIR)/Screens \
             -I$(CORE_INC) -I$(MINISIP) -I$(QR)
CFLAGS    := $(ARCH) $(MINVER) $(SYSROOT) -Wall -O2 -I$(MINISIP) -I$(CORE_INC) -I$(QR)

FRAMEWORKS := -framework Foundation -framework UIKit -framework CoreGraphics \
              -framework QuartzCore -framework CFNetwork -framework AudioToolbox \
              -framework CoreAudio -framework AVFoundation -framework Security \
              -framework CoreFoundation -framework SystemConfiguration \
              -framework ImageIO -framework MediaPlayer
# 静的 C++ ランタイム (順序: c++ → c++abi → unwind → builtins)。libdoorbell_all.a が要求。
RTLIBS := $(TC_LIB)/libc++.a $(TC_LIB)/libc++abi.a $(TC_LIB)/libunwind.a $(CLANG_RT)

OBJC_SRCS := $(shell find $(SRC_DIR) -name '*.m' | sort)
CPP_SRCS  := $(shell find $(SRC_DIR) -name '*.cpp' | sort)
C_SRCS    := $(MINISIP)/minisip.c $(MINISIP)/sip.c $(MINISIP)/sdp.c \
             $(MINISIP)/rtp.c $(MINISIP)/g711.c
QR_SRCS   := $(QR)/qrcodegen.c

OBJC_OBJS := $(patsubst $(SRC_DIR)/%.m,$(OBJ)/%.o,$(OBJC_SRCS))
CPP_OBJS  := $(patsubst $(SRC_DIR)/%.cpp,$(OBJ)/%.o,$(CPP_SRCS))
C_OBJS    := $(patsubst $(MINISIP)/%.c,$(OBJ)/minisip_%.o,$(C_SRCS))
QR_OBJS   := $(patsubst $(QR)/%.c,$(OBJ)/qr_%.o,$(QR_SRCS))
ALL_OBJS  := $(OBJC_OBJS) $(CPP_OBJS) $(C_OBJS) $(QR_OBJS)

EXE := $(APP)/Doorbell
HOST_TS_TEST := $(BUILD)/host/test_ts_mux

.PHONY: all app test verify clean

all: app

$(OBJ):
	@mkdir -p $(OBJ)

$(OBJ)/%.o: $(SRC_DIR)/%.m | $(OBJ)
	@mkdir -p $(dir $@)
	$(CLANG) $(OBJCFLAGS) -c $< -o $@

$(OBJ)/%.o: $(SRC_DIR)/%.cpp | $(OBJ)
	@mkdir -p $(dir $@)
	$(CLANG) $(ARCH) $(MINVER) $(SYSROOT) -Wall -O2 -std=c++11 -I$(CORE_INC) -c $< -o $@

$(OBJ)/minisip_%.o: $(MINISIP)/%.c | $(OBJ)
	$(CLANG) $(CFLAGS) -c $< -o $@

$(OBJ)/qr_%.o: $(QR)/%.c | $(OBJ)
	$(CLANG) $(CFLAGS) -c $< -o $@

# libdoorbell_all.a を依存に含める — core 再ビルド時に app を確実に再リンクする
$(EXE): $(ALL_OBJS) $(LIB_DIR)/libdoorbell_all.a
	@mkdir -p $(APP)
	$(CLANG) $(ARCH) $(MINVER) $(SYSROOT) -o $@ \
	  $(ALL_OBJS) $(LIB_DIR)/libdoorbell_all.a $(RTLIBS) $(FRAMEWORKS)

app: $(EXE)
	@cp $(SRC_DIR)/Info.plist $(APP)/Info.plist
	@cp $(SRC_DIR)/Resources/*.png $(APP)/ 2>/dev/null || true
	@$(LDID) -S $(EXE)
	@echo "ok: $(APP)"

$(HOST_TS_TEST): $(KIOSK)/tests/test_ts_mux.cpp $(SRC_DIR)/Media/DBTsMux.cpp \
                 $(SRC_DIR)/Media/DBTsMux.h
	@mkdir -p $(dir $@)
	$(CXX) -isysroot $(MACOS_SDK) -std=c++11 -Wall -Wextra -Werror -O2 \
	  $(KIOSK)/tests/test_ts_mux.cpp $(SRC_DIR)/Media/DBTsMux.cpp -o $@

test: $(HOST_TS_TEST)
	$(HOST_TS_TEST)

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

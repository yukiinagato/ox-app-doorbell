ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
SRC_DIR := $(ROOT)/ios-kiosk/src
QR := $(ROOT)/ios-kiosk/qr
CORE_INC := $(ROOT)/core/include

ifndef DB_IOS9_BUILD_ROOT
$(error DB_IOS9_BUILD_ROOT is required)
endif
ifndef DB_IOS9_SDK_ROOT
$(error DB_IOS9_SDK_ROOT is required)
endif
ifndef DB_IOS9_CLANG
$(error DB_IOS9_CLANG is required)
endif
ifndef DB_IOS9_CORE_ARCHIVE
$(error DB_IOS9_CORE_ARCHIVE is required)
endif
ifndef DB_IOS9_INFO_PLIST
$(error DB_IOS9_INFO_PLIST is required)
endif
ifndef DB_IOS9_CLANG_RT
$(error DB_IOS9_CLANG_RT is required)
endif
ifndef DB_IOS9_LIPO
$(error DB_IOS9_LIPO is required)
endif
ifndef DB_IOS9_OTOOL
$(error DB_IOS9_OTOOL is required)
endif
ifndef DB_IOS9_NM
$(error DB_IOS9_NM is required)
endif

BUILD := $(DB_IOS9_BUILD_ROOT)
OBJ := $(BUILD)/obj
APP := $(BUILD)/Doorbell.app
EXE := $(APP)/Doorbell

ARCH := -arch armv7
MINVER := -miphoneos-version-min=9.0
SYSROOT := -isysroot $(DB_IOS9_SDK_ROOT)
PROFILE_DEFINES := -DDB_IOS_COMPAT_OS_FLOOR=90000 \
  -DDB_IOS_COMPAT_CORE_PJSIP=1 -DDB_IOS_COMPAT_PUBLIC_VIDEOTOOLBOX=1 \
  -DDB_IOS_COMPAT_DEVICE_FAMILY_PHONE=1 -DDB_IOS_COMPAT_DEVICE_FAMILY_IPAD=1

OBJCFLAGS := $(ARCH) $(MINVER) $(SYSROOT) -fobjc-arc -Wall -Wextra -Werror \
  -Wno-error=deprecated-declarations \
  $(PROFILE_DEFINES) -I$(SRC_DIR) -I$(SRC_DIR)/Support -I$(SRC_DIR)/Core \
  -I$(SRC_DIR)/Net -I$(SRC_DIR)/Media -I$(SRC_DIR)/Screens -I$(CORE_INC) -I$(QR)
CFLAGS := $(ARCH) $(MINVER) $(SYSROOT) -Wall -Wextra -Werror -I$(CORE_INC) -I$(QR)
CXXFLAGS := $(ARCH) $(MINVER) $(SYSROOT) -std=c++11 -Wall -Wextra -Werror \
  -nostdinc++ -isystem $(ROOT)/tools/toolchain/ios5-armv7/include/c++/v1 -I$(CORE_INC)

FRAMEWORKS := -framework Foundation -framework UIKit -framework CoreGraphics \
  -framework QuartzCore -framework CFNetwork -framework AudioToolbox -framework AudioUnit \
  -framework CoreAudio -framework AVFoundation -framework Security -framework CoreFoundation \
  -framework SystemConfiguration -framework ImageIO -framework MediaPlayer \
  -framework CoreMedia -framework CoreVideo -framework OpenGLES -framework GLKit \
  -framework VideoToolbox
RTLIBS := $(ROOT)/tools/toolchain/ios5-armv7/lib/libc++.a \
  $(ROOT)/tools/toolchain/ios5-armv7/lib/libc++abi.a \
  $(ROOT)/tools/toolchain/ios5-armv7/lib/libunwind.a $(DB_IOS9_CLANG_RT)

# MiniSIP implementations and C sources are intentionally absent. The shared
# Router compiles its Core/PJSIP adapter under DB_IOS_COMPAT_CORE_PJSIP.
OBJC_SRCS := $(shell find $(SRC_DIR) -name '*.m' \
  ! -path '*/Media/DBSipSession.m' ! -path '*/Media/DBSipListener.m' | sort)
CPP_SRCS := $(shell find $(SRC_DIR) -name '*.cpp' | sort)
QR_SRCS := $(QR)/qrcodegen.c
OBJC_OBJS := $(patsubst $(SRC_DIR)/%.m,$(OBJ)/%.o,$(OBJC_SRCS))
CPP_OBJS := $(patsubst $(SRC_DIR)/%.cpp,$(OBJ)/%.o,$(CPP_SRCS))
QR_OBJS := $(patsubst $(QR)/%.c,$(OBJ)/qr_%.o,$(QR_SRCS))
ALL_OBJS := $(OBJC_OBJS) $(CPP_OBJS) $(QR_OBJS)

.PHONY: app verify clean

$(OBJ):
	@mkdir -p $(OBJ)

$(OBJ)/%.o: $(SRC_DIR)/%.m | $(OBJ)
	@mkdir -p $(dir $@)
	$(DB_IOS9_CLANG) $(OBJCFLAGS) -c $< -o $@

$(OBJ)/%.o: $(SRC_DIR)/%.cpp | $(OBJ)
	@mkdir -p $(dir $@)
	$(DB_IOS9_CLANG) $(CXXFLAGS) -c $< -o $@

$(OBJ)/qr_%.o: $(QR)/%.c | $(OBJ)
	$(DB_IOS9_CLANG) $(CFLAGS) -c $< -o $@

$(EXE): $(ALL_OBJS) $(DB_IOS9_CORE_ARCHIVE)
	@mkdir -p $(APP)
	$(DB_IOS9_CLANG) $(ARCH) $(MINVER) $(SYSROOT) -o $@ \
	  $(ALL_OBJS) $(DB_IOS9_CORE_ARCHIVE) $(RTLIBS) $(FRAMEWORKS)

app: $(EXE)
	@cp $(DB_IOS9_INFO_PLIST) $(APP)/Info.plist
	@cp $(SRC_DIR)/Resources/*.png $(APP)/ 2>/dev/null || true
	@cp $(ROOT)/assets/audio/*.mp3 $(APP)/
	@echo "ok: $(APP)"

verify: app
	@test "$$($(DB_IOS9_LIPO) -archs $(EXE))" = armv7
	@test "$$($(DB_IOS9_OTOOL) -l $(EXE) | awk ' \
	  $$1 == "cmd" && $$2 == "LC_VERSION_MIN_IPHONEOS" { in_min = 1; next } \
	  in_min && $$1 == "version" { print $$2; exit }')" = 9.0
	@$(DB_IOS9_NM) -gU $(EXE) | grep -Eq '(^|[[:space:]])_db_core_create_v2$$'
	@for symbol in _pjsua_create _pjsua_call_make_call _pjsua_call_answer; do \
	  $(DB_IOS9_NM) -gU $(EXE) | grep -Eq "(^|[[:space:]])$$symbol$$" || exit 1; \
	done
	@! $(DB_IOS9_NM) -u $(EXE) | grep -Eq '(^|[[:space:]])_pjsua_'
	@! $(DB_IOS9_NM) $(EXE) | grep -Eq '(^|[[:space:]])_ms_(call|listen|poll|hangup)'
	@! $(DB_IOS9_NM) -u $(EXE) | grep -Eq '(^|[[:space:]])_(dlopen|dlsym)$$'
	@$(DB_IOS9_NM) -u $(EXE) | grep -Eq '(^|[[:space:]])_VTDecompressionSessionCreate$$'
	@$(DB_IOS9_NM) -u $(EXE) | grep -Eq '(^|[[:space:]])_VTDecompressionSessionDecodeFrame$$'

clean:
	rm -rf $(BUILD)

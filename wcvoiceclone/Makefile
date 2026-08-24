TARGET := iphone:clang:14.5:14.0
INSTALL_TARGET_PROCESSED = YES

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WCVoiceClone

WCVoiceClone_FILES = Tweak.x \
	src/FAVoiceAPI.m \
	src/PrefsManager.m \
	src/SilkBridge.m \
	$(wildcard src/silk/src/*.c)

WCVoiceClone_CFLAGS = -fobjc-arc -Isrc/silk/interface -DHAVE_SILK
WCVoiceClone_FRAMEWORKS = UIKit Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MultiTA

MultiTA_FILES = Tweak.xm
MultiTA_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MultiTA_CCFLAGS = -std=c++14
MultiTA_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

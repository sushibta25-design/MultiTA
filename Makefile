ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TAduo

TAduo_FILES = Tweak.xm
TAduo_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TAduo_CCFLAGS = -std=c++14
TAduo_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

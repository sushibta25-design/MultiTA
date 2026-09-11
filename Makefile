ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DuoPhone

DuoPhone_FILES = Tweak.xm
DuoPhone_CFLAGS = -fobjc-arc -Werror
DuoPhone_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

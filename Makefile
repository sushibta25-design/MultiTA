ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MultiTABeta

MultiTABeta_FILES = Tweak.xm
MultiTABeta_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -std=c++17
MultiTABeta_CXXFLAGS = -std=c++17
MultiTABeta_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

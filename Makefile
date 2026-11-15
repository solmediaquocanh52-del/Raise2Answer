TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Raise2Answer
Raise2Answer_FILES = Tweak.x
Raise2Answer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
Raise2Answer_FRAMEWORKS = UIKit CoreMotion CoreTelephony

include $(THEOS_MAKE_PATH)/tweak.mk

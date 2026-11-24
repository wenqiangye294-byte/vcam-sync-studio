THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.2:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamTweak
VCamTweak_FILES = VCamHookEntry.m VCamAVFoundationHook.m VCamMediaRenderer.m VCamQueueStore.m VCamFloatingHUD.m
VCamTweak_CFLAGS = -fobjc-arc -I../shared
VCamTweak_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo CoreImage ImageIO QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

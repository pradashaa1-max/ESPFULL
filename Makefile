# mark (antilose64) — darling
# export THEOS=~theos
# make clean && make
# → .theos/obj/mark.dylib

TARGET := iphone:clang:latest:14.0
ARCHS = arm64
DEBUG = 0

LIBRARY_NAME = mark

mark_FILES = src/Menu.mm src/Features.mm
mark_CFLAGS = -fobjc-arc -O2 -Iinclude -Wno-unused-function -Wno-unused-variable -fexceptions -fvisibility=hidden
mark_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
mark_INSTALL_PATH = /usr/lib
mark_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk

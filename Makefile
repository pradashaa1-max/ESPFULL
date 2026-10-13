# Theos library — arm64 iOS dylib
# export THEOS=~theos   (or $HOME/theos)
# make clean && make
# → .theos/obj/AstralCheat.dylib

TARGET := iphone:clang:latest:14.0
ARCHS = arm64
DEBUG = 0

LIBRARY_NAME = AstralCheat

AstralCheat_FILES = src/Menu.mm src/Features.mm
AstralCheat_CFLAGS = -fobjc-arc -O2 -Iinclude -Wno-unused-function -Wno-unused-variable -fexceptions -fvisibility=hidden
AstralCheat_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
AstralCheat_INSTALL_PATH = /usr/lib
AstralCheat_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk

# Theos Makefile — arm64 dylib for iOS
# export THEOS=~theos
# make clean && make
# → .theos/obj/AstralCheat.dylib

TARGET := iphone:clang:latest:14.0
ARCHS  = arm64
DEBUG  = 0

LIBRARY_NAME = AstralCheat

AstralCheat_FILES = src/Menu.mm src/Features.mm
AstralCheat_CFLAGS = -fobjc-arc -O2 -Iinclude -Wno-unused-function -Wno-unused-variable -fexceptions
AstralCheat_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
AstralCheat_INSTALL_PATH = /usr/lib

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk

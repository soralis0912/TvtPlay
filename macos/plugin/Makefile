HOST_SDK ?= ../../../TVTest/macos
VLC_APP ?= /Applications/VLC.app
VLC_ROOT := $(VLC_APP)/Contents/MacOS
BUNDLE ?= build/TvtPlay.bundle

.PHONY: all
all:
	@test -f "$(HOST_SDK)/TVTestPlaybackPlugin.h" || { echo "Set HOST_SDK to the TVTest fork's macos directory." >&2; exit 1; }
	@test -f "$(VLC_ROOT)/include/vlc/vlc.h" && test -f "$(VLC_ROOT)/lib/libvlc.dylib" || { echo "Install VLC 3 in /Applications or set VLC_APP." >&2; exit 1; }
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	xcrun clang -bundle -fobjc-arc -mmacosx-version-min=12.0 -Wall -Wextra -O2 -framework AppKit \
	    -I"$(HOST_SDK)" -I"$(VLC_ROOT)/include" -L"$(VLC_ROOT)/lib" \
	    -Xlinker -rpath -Xlinker "$(VLC_ROOT)/lib" -lvlc TvtPlayPlugin.m -o "$(BUNDLE)/Contents/MacOS/TvtPlay"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"

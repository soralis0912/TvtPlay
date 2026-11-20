SWIFTC ?= xcrun swiftc
PLAYER := build/tvtplay

.PHONY: all clean

all: $(PLAYER)

$(PLAYER): main.swift Makefile
	mkdir -p $(@D)
	$(SWIFTC) -O main.swift -o $@

clean:
	rm -f $(PLAYER)

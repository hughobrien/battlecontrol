# Build the stub THIPX32.DLL for Wine 11.0 wow64 compatibility.
# The original THIPX32.DLL depends on 16-bit THIPX16.DLL thunking which
# Wine wow64 does not support. This stub provides the same exports but
# returns sensible defaults.
#
# Requirements: i686-w64-mingw32-gcc (mingw-w64 cross compiler)
#
# Usage:
#   make          # build thipx32.dll
#   make clean    # remove build artifacts
#   make install  # copy to game staging directories (requires sudo)
#   make check    # verify exports match RA95.EXE import table

CC = i686-w64-mingw32-gcc
CFLAGS = -shared -Os -s
LDFLAGS = -Wl,--kill-at

TARGET = thipx32.dll
SRCS = stub.c
DEPS = thipx32.def

.PHONY: all clean install check

all: $(TARGET)

$(TARGET): $(SRCS) $(DEPS)
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(DEPS) $(LDFLAGS)
	@echo "=== Built $@ ==="
	@i686-w64-mingw32-objdump -p $@ | grep -A 30 "Ordinal/Name" | head -25

clean:
	rm -f $(TARGET) *.o

install: $(TARGET)
	cp $(TARGET) /opt/redalert/game/THIPX32.DLL
	@echo "Installed to /opt/redalert/game/THIPX32.DLL"

check: $(TARGET)
	@echo "=== Checking exports ==="
	i686-w64-mingw32-objdump -p $(TARGET) | grep -A 30 "Ordinal/Name"
	@echo ""
	@echo "=== Imported by RA95.EXE (for reference) ==="
	i686-w64-mingw32-objdump -p /opt/redalert/game/RA95.EXE.orig 2>/dev/null | grep -A 20 "thipx32"

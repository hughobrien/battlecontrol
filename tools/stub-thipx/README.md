# Stub THIPX32.DLL for Wine compatibility

RA95.EXE imports thipx32.dll (IPX networking) at load time. The original
thipx32.dll uses Wine's 16-bit thunk layer to delegate to THIPX16.DLL
(16-bit NE format). Wine 11.0 wow64 from Nix does not support these 16-bit
thunks, causing the game to abort during DLL initialization.

This stub provides the same exports as the original thipx32.dll but
returns sensible defaults without loading THIPX16.DLL.

Works with both Wine 11.0 (wow64) and regular Wine builds.

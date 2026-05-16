# TIM-824 Native Linux RA Runtime Smoke Test Report

**Date:** 2026-05-16
**Host:** Debian 13 trixie, x86_64, g++ 14.2.0, SDL2, Xvfb :99
**Build:** cmake -S . -B build && cmake --build build --target ra -j$(nproc)

## Build Status

All 301 source files compile and link cleanly. Binary: 19MB PIE ELF x86_64 with debug info.

## Subsystem Status

| Subsystem | Status | Details |
|-----------|--------|---------|
| **File I/O (MIX loading)** | ✅ | MAIN.MIX (454MB), REDALERT.MIX (25MB), EXPAND.MIX (447KB), LOCAL.MIX (3.8MB) all load with RSA+Blowfish decryption |
| **RSA decryption** | ✅ | All encrypted MIX files decrypt cleanly (EXPAND, REDALERT, MAIN, LOCAL) |
| **SDL2 graphics init** | ✅ | 640x480 SDL_Window + SDL_Renderer created, palette rendering OK |
| **SDL2 audio init** | ✅ | `Audio_Init: SDL2 audio opened OK` |
| **Scenario load** | ✅ | Start_Scenario('SCG01EA.INI') loads GDI Mission 1 East |
| **Game loop** | ✅ | Main_Loop runs at consistent 15.0-15.2 fps |
| **AI/logic** | ✅ | Factory production, unit movement, combat, death events all active |
| **Credit grant (RA_CHEAT)** | ✅ | [RA-CHEAT] frame 30: +10000 credits |
| **Tech unlock (RA_CHEAT)** | ✅ | [RA-CHEAT] frame 35: Debug_Cheat=true (tech-level 98) |
| **Map reveal (RA_CHEAT)** | ✅ | [RA-CHEAT] frame 40: Debug_Unshroud=true |
| **Win sequence (RA_CHEAT)** | ✅ | [RA-CHEAT] frame 200: Flag_To_Win fired |
| **Scenario transition** | ✅ | After Flag_To_Win, Select_Game re-entered and next mission started |

## Issues Found

### ⚠️ Audio log spam (moderate)
`File_Stream_Sample_Vol` fires ~2× per frame (21,861 of 22,990 log lines = 95%). Audio subsystem re-opens sound files every frame instead of caching. With `SDL_AUDIODRIVER=dummy` this is harmless; with real audio it would cause crackling. Root cause in `AUDIO.CPP` or sound effect call sites.

### ⚠️ No clean exit after autostart scenario
After debrief sequence, `RA_AUTOSTART=1` triggers a new scenario loop instead of exiting. The `timeout 90` had to SIGKILL the process. For CI, need `RA_AUTOSTART_ONCE=1` or equivalent.

### ✅ No crashes, segfaults, or memory errors detected
The binary ran through 1300+ frames, completed a mission, and started the next without incident.

## Verification Commands

```bash
# Build
cmake -S . -B build && cmake --build build --target ra -j$(nproc)

# Set up run dir
mkdir -p build/ra-smoke
cd build/ra-smoke
ln -sf /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX .
ln -sf /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/REDALERT.MIX .
ln -sf /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/REDALERT.INI .
ln -sf /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/EXPAND.MIX .
cp ../ra .

# Run
Xvfb :99 -screen 0 640x480x24 -ac &
DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 RA_CHEAT=1 timeout 90 ./ra
```

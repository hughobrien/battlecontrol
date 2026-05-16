# Win32 / DOS / project stub headers + implementations

This directory provides the minimum-viable Win32/DOS API surface so the
original Command & Conquer source trees compile on Linux.  Headers and
source files are loaded as a last-resort include path — they fire only
when no real system or game header provides the name.

## Files (63 total: 45 headers, 12 implementation .cpp, 1 README)

### Headers with real inline implementations

| File | Functions | Purpose |
|------|-----------|---------|
| `windows.h` (1571 L) | ~90 inline/template stubs (GetSystemTimeAsFileTime, CreateFileA, CloseHandle, ReadFile, WriteFile, SetFilePointer, GetFileSize, FindFirstFileA, MessageBoxA, PeekMessage, GetAsyncKeyState, etc.) + ~40 struct typedefs + ~100 macros | Core Win32 type taxonomy — the largest and most important stub. Every TU gets it via `msvc-compat.h` → `windows.h` |
| `mmsystem.h` | `timeBeginPeriod`, `timeEndPeriod`, `timeGetTime`, `timeSetEvent`, `timeKillEvent`, `mmioOpen`, `mmioClose`, `mmioRead`, `mmioWrite`, `mmioSeek` | Win32 multimedia API (inert). Pulled transitively from `windows.h` |
| `winsock.h` (573 L) | `WSAStartup`, `WSACleanup`, `closesocket`, `socket`, `bind`, `sendto`, `recvfrom`, `gethostbyname`, `inet_addr`, `inet_ntoa`, `WSAAsyncSelect`, `accept`, etc. (~25 inline stubs) | Winsock 1.1 surface (dormant — all return SOCKET_ERROR or 0). Pulled transitively from `windows.h` |
| `msvc-compat.h` (699 L) | `_aligned_malloc`, `_aligned_free`, `_stricmp`→`strcasecmp`, `itoa`, `_lrotl`, `_splitpath`, `_makepath`, `SafeArrayCreate`, `SafeArrayAccessData`, `SafeArrayUnaccessData`, calling-convention macros (~50), `__int64`→`long long` | Force-included via `-include` for all non-MSVC TUs. Cross-cutting MSVC/Watcom compat |
| `objbase.h` | `OleInitialize`, `OleUninitialize`, `IUnknown`, COM macros | COM interface taxonomy for DSOUND.H / DDRAW.H |
| `conio.h` | `getch()` inline → `getchar()` | DOS console I/O |
| `execinfo.h` | `backtrace`, `backtrace_symbols`, `backtrace_symbols_fd` | glibc backtrace for Emscripten/musl |
| `memory.h` | `MemoryClass::Free`, `MemoryClass::operator bool`, `free(void const*)`, `extern MemoryClass Mem`, `extern bool GameActive` | Shadows glibc `<memory.h>` for AUDIO.H |
| `dos.h` | `_dos_open`, `_dos_creat`, `_dos_close`, `_dos_read`, `_dos_write`, `_dos_getftime`, `_dos_setftime` (all return 0) | Watcom DOS file-API templates |
| `io.h` | `filelength`, `lseek` (both return 0) | MSVC file-size / seek for dormant DOS branches |

### Headers — structs / typedefs / macros only

| File | Content |
|------|---------|
| `ddeml.h` | DDEML handle taxonomy (HSZ, HCONV, HDDEDATA, HCONVLIST). Pulled transitively from `windows.h` |
| `i86.h` | Watcom DOS register shape: `DWORDREGS`, `WORDREGS`, `BYTEREGS`, `union REGS`, `int386()`→`0` macro |
| `mplib.h` | MPath function declarations (bodies in REDALERT/MPLIB.CPP): `Yield`, `PostWindowsMessage`, `MGenGetQueueCtr`, etc. |
| `mplpc.h` | `LPCGetMPAddr` declaration (body in `mpath-stub.cpp`) |
| `mgenord.h` | MGen VxD ordinals (all 0) |
| `rtq.h` | `RTQ_NODE` struct for `sizeof()` in MPMGRD.CPP |
| `services.h` | `GetGameDef` declaration (body in `mpath-stub.cpp`) |
| `wsipx.h` | `SOCKADDR_IPX` struct |
| `posix_fileio.h` | `RA_PosixFile_*` declarations (bodies in `posix_fileio.cpp`) |
| `sdl_audio.h` | `SDL_Audio_*` declarations (bodies in REDALERT/AUDIO.CPP) |
| `sdl_input.h` | `SDL_Process_Input_Events` declaration (body in REDALERT/KEYBOARD.CPP) |
| `sdl_quit.h` | `SDL_Quit_Requested`, `SDL_Clear_Quit` declarations (bodies in DDRAW.CPP / td-win32-stubs.cpp) |
| `sdl_window.h` | `SDL_*_Main_Window` declarations (bodies in `sdl_window.cpp`) |
| `vqa_player.h` | `Play_Movie_Linux`, `Set_DD_Palette_8bit` declarations (bodies in `vqa_player.cpp`) |
| `share.h` | File-sharing constants: `SH_COMPAT`, `SH_DENYRW`, etc. |

### Headers — empty placeholders (needed for `#include` resolution)

`alloc.h`, `bios.h`, `commctrl.h`, `commlib.h`, `digitalv.h`, `direct.h`,
`magic.h`, `mem.h`, `mplayer.h`, `new.h`, `nspapi.h`, `oaidl.h`,
`ole2.h`, `olectl.h`, `oleidl.h`, `PassEdit.h`, `process.h`, `rpc.h`,
`rpcndr.h`, `svcguid.h`, `ten.h`, `types.h`, `unchecked.h`,
`windowsx.h`, `winerror.h`

### Implementation files (.cpp) — compiled per target

| File | Functions | Target(s) | Purpose |
|------|-----------|-----------|---------|
| `posix_fileio.cpp` (481 L) | `CreateFileA`, `CloseHandle`, `ReadFile`, `WriteFile`, `SetFilePointer`, `GetFileSize` **+** `RA_PosixFile_*` substrate | `td`, `ra` | **Real** POSIX-backed file I/O via `open/read/write/lseek/fstat/close`. Case-fold fallback |
| `vqa_player.cpp` (1355 L) | `Play_Movie_Linux` + LCW decompress, SND1/SND2 ADPCM, SDL2/WebAudio output | `td`, `ra` | **Real** VQA cinematic player |
| `sdl_window.cpp` (162 L) | `SDL_Get/Set_Main_Window/Renderer`, `SDL_Toggle_Fullscreen` | `td`, `ra` | **Real** SDL2 window lifecycle |
| `kernel32-stub.cpp` | `GetSystemTimeAsFileTime` (real `clock_gettime`→FILETIME) | `td`, `ra` | **Real** system time conversion |
| `wwlib-asm-stub.cpp` (298 L) | `Buffer_Print`, `Buffer_Frame_To_Page` (real C++ ports of ASM), `Detect_MMX_Availability`, `LCW_Comp`, `Processor` (NOP) | `ra` only (glob) | Replaces x86 ASM modules (TXTPRNT, KEYFBUFF, MMX, CPUID, LCWCOMP) |
| `internet-stub.cpp` | `Check_From_WChat`, `Spawn_WChat`, `Read_Game_Options`, `Send_Statistics_Packet`, etc. + globals | `ra` only (glob) | Umbrella-A stubs for INTERNET.CPP, STATS.CPP, TCPIP.CPP, CCDDE.CPP |
| `tcpip-dde-stub.cpp` (61 L) | `TcpipManagerClass` + `DDEServerClass` NOP bodies | `ra` only (glob) | Winsock/DDE class stubs (TCPIP.CPP, CCDDE.CPP) |
| `stop-execution-stub.cpp` | `Stop_Execution` (NOP), `DLL_Startup` (NOP) | `ra` only (glob); explicitly **excluded** from `td` | x86 halt / DLL entry replacement |
| `mpath-stub.cpp` | `LPCGetMPAddr` (returns 0), `GetGameDef` (zero-init) | `ra` only (glob) | MPath/LPC service bodies |
| `netdlg-stub.cpp` | `Net_Reconnect_Dialog` (NOP), `Reconnect_Modem` (NOP) | `ra` only (glob) | Network reconnect dialog stubs |
| `oleaut32-stub.cpp` | `SafeArrayCreate` (returns NULL), `SafeArrayAccessData`, `SafeArrayUnaccessData` (E_NOTIMPL) | `ra` only (glob) | OLE Automation runtime for DLLInterfaceEditor.cpp |

### Related file: `linux/td-win32-stubs.cpp` (1387 L)
Not in `linux/win32-stubs/` but provides the same kind of Linux implementations for the `td` target:
- **Real implementations**: GraphicViewPortClass, GraphicBufferClass, BufferClass, TimerClass, CountDownTimerClass, WinTimerClass, WWKeyboardClass, WWMouseClass, Set_Font, Char/String_Pixel_Width, Alloc/Free/Ram_Free, Random/IRandom, Set_Palette/Fade_Palette_To, Set_Video_Mode, Wait_Vert_Blank, Buffer_Put_Pixel/Buffer_Clear/Buffer_Fill_Rect/Buffer_Draw_Stamp, Clip_Rect/Confine_Rect, Set_DD_Palette_8bit, SDL_Window_Show/Raise, Font glyph rendering
- **NOP stubs**: LCW_Uncompress, Apply_XOR_Delta, Buffer_To_Buffer, Buffer_Print, Uncompress_Data, Extract_Shape, Open/Close_Animation, IconCacheClass methods, Instance_Class, DLL callbacks, most extern "C" draw helpers

## Build target inclusion

| Target | Stubs included |
|--------|---------------|
| `td` (Tiberian Dawn) | Explicit list: `linux/win32-stubs/{kernel32-stub,sdl_window,posix_fileio,vqa_player}.cpp` + `linux/td-win32-stubs.cpp` |
| `ra` (Red Alert) | Glob `linux/win32-stubs/*.cpp` — all 12 implementation files + all headers on include path |

## Audit results (TIM-840)

- **Total files**: 63 (45 headers, 12 .cpp, 1 README, 1 uppercase alias `WINDOWS.H`, 1 force-included `msvc-compat.h`)
- **Total stub functions/declarations**: ~230 inline/template stubs across headers + ~150 function definitions across .cpp files
- **Dead (zero-reference) files found**: **0** — every file is referenced by at least one `#include` or provides symbols linked by game code
- **Build status**: both `td` and `ra` compile and link cleanly (verified in TIM-840 worktree)
- **Conclusion**: No stubs can be removed at this time. All 63 files serve an active purpose in the Linux port.

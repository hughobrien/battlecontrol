# dde.h:97 bucket — pass-26 shared prefix (TIM-52)

All 7 TUs in the pass-26 `dde.h:97` first-error bucket reach `dde.h` via
`ccdde.h` (which `#include`s `dde.h` under `#ifdef WIN32`) and fail with
the same 9-line shared prefix:

| dde.h line | Diagnostic                                        |
| ---------: | ------------------------------------------------- |
|         97 | `'HSZ' has not been declared` (Test_Server_Running param) |
|        107 | `'HSZ' has not been declared` (Open_Poke_Connection param) |
|        133 | `'HDDEDATA' does not name a type` (dde_callback return) |
|    159–163 | `'HSZ' does not name a type` (5 string-handle members) |
|        165 | `'HCONV' does not name a type` (conv_handle member) |

Translation-units in the bucket (canonical = CONQUER.CPP):

- REDALERT/CONQUER.CPP
- REDALERT/EVENT.CPP
- REDALERT/INIT.CPP
- REDALERT/MENUS.CPP
- REDALERT/SAVELOAD.CPP
- REDALERT/SCENARIO.CPP
- REDALERT/STARTUP.CPP

Root cause: REDALERT/DDE.H references the Win32 DDEML handle types
(`HSZ`, `HCONV`, `HDDEDATA`) without including `<ddeml.h>`. Upstream's
Win32 build relied on a /FI or PCH path to make the taxonomy globally
visible — same shape as TIM-51's tcpip.h/winsock.h gap.

Fix: new `linux/win32-stubs/ddeml.h` with opaque `void*` typedefs for
`HSZ`, `HCONV`, `HDDEDATA`, `HCONVLIST`, plus a transitive
`#include "ddeml.h"` from `linux/win32-stubs/windows.h` (next to the
TIM-46 mmsystem.h and TIM-51 winsock.h pulls).

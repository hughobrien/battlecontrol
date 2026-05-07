/* TIM-5 / TIM-47 stub: objbase.h.
 *
 * Provides the minimum-viable Win32 COM glue needed for DSOUND.H's
 * `DECLARE_INTERFACE_` blocks to parse on Linux. The rest of the COM
 * surface (CoCreateInstance, vtable layout, real IUnknown semantics)
 * stays out of scope; we never run the COM activation path.
 *
 * History:
 *   - TIM-5:  empty placeholder so direct `#include <objbase.h>`
 *             resolved.
 *   - TIM-11: kept `_NO_COM` defined defensively so DDRAW.H's COM
 *             block stayed gated even if the force-include shim were
 *             ever bypassed.
 *   - TIM-47: shimmed the DECLARE_INTERFACE_ / STDMETHOD / IUnknown
 *             macro family so DSOUND.H#140 (`DECLARE_INTERFACE_(
 *             IDirectSound, IUnknown)`) and the matching IDirectSound
 *             Buffer block at #180 parse on Linux. Cleared the 179-TU
 *             first-error cohort that had relocated to DSOUND.H#140
 *             from #111 across passes 22-23.
 *
 * IUnknown ordering note: DDRAW.H#31 unconditionally `#define
 * IUnknown void` when `_NO_COM` is in effect (so its own COM block
 * stays skipped and `IUnknown FAR *` parameters in skipped blocks
 * substitute trivially). DSOUND.H is the outlier: its COM block is
 * gated only by `_WIN32`, not `_NO_COM`. DSOUND.H always `#include
 * <objbase.h>` near the top, after ddraw.h has been pulled in via the
 * gbuffer.h chain, so this header runs *after* the ddraw.h macro and
 * can `#undef` it. Do NOT wire `objbase.h` into the force-included
 * `windows.h` chain — that order-of-operations would leave the
 * ddraw.h `#define IUnknown void` shadowing our struct for the rest
 * of the TU.
 */
#ifndef LINUX_STUBS_OBJBASE_H_INCLUDED
#define LINUX_STUBS_OBJBASE_H_INCLUDED

/* TIM-11: defensive mirror of msvc-compat.h's `_NO_COM` so a direct
 * `#include <objbase.h>` from upstream code still gates DDRAW.H's COM
 * block off on Linux even if the force-include shim were ever
 * bypassed. */
#ifndef _NO_COM
#define _NO_COM
#endif

/* TIM-47: pull in the windows.h taxonomy so HRESULT / ULONG / REFIID
 * / LPVOID / LPDWORD / GUID etc. are visible by the time the COM
 * macros below expand inside DSOUND.H interface bodies. windows.h is
 * already force-included via msvc-compat.h on every TU; this is a
 * belt-and-braces include for any caller that pulls objbase.h
 * directly. */
#include "windows.h"

#ifdef __cplusplus

/* DDRAW.H#31 expands to `#define IUnknown void`. We need IUnknown to
 * be a real, complete type so DSOUND.H#140's `DECLARE_INTERFACE_(
 * IDirectSound, IUnknown)` can derive from it. Undef the ddraw.h
 * macro before declaring the struct. */
#ifdef IUnknown
#undef IUnknown
#endif

#ifndef LINUX_STUBS_OBJBASE_IUNKNOWN_DEFINED
#define LINUX_STUBS_OBJBASE_IUNKNOWN_DEFINED
struct IUnknown { };
#endif

/* COM macro family used by DSOUND.H#140-156 (IDirectSound) and
 * DSOUND.H#180-206 (IDirectSoundBuffer). Expansions are pure parser
 * glue — abstract structs are emitted but never instantiated, and
 * `__stdcall` is already a no-op via msvc-compat.h. THIS_ collapses
 * to nothing in C++ form (the implicit `this` is invisible). PURE
 * yields `= 0` to mark each method pure-virtual, mirroring the real
 * objbase.h. */
#ifndef DECLARE_INTERFACE
#define DECLARE_INTERFACE(iface)            struct iface
#endif
#ifndef DECLARE_INTERFACE_
#define DECLARE_INTERFACE_(iface, parent)   struct iface : public parent
#endif
#ifndef STDMETHOD
#define STDMETHOD(method)                   virtual HRESULT __stdcall method
#endif
#ifndef STDMETHOD_
#define STDMETHOD_(type, method)            virtual type __stdcall method
#endif
#ifndef THIS_
#define THIS_
#endif
#ifndef THIS
#define THIS                                void
#endif
#ifndef PURE
#define PURE                                = 0
#endif

#endif /* __cplusplus */

#endif /* LINUX_STUBS_OBJBASE_H_INCLUDED */

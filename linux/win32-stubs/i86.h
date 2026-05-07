/* TIM-9 stub: i86.h — Watcom DOS register-union shape.
 *
 * Originally provided `union REGS` and the DPMI int86() helpers for
 * Watcom's 32-bit DOS extender. We only need the union to be a
 * COMPLETE type so REDALERT/MPLIB.CPP's `typedef union REGS REGISTERS;`
 * followed by `REGISTERS regs;` parses (pass-3 "incomplete type"
 * errors). REDALERT/IPX*.CPP also access regs.x.eax / regs.x.cflag
 * etc., so the WORDREGS/DWORDREGS member layout matches Watcom's
 * <i86.h> exactly.
 *
 * No int86() / int386() shim — those are bucket-7 work (TIM-10+).
 */
#ifndef LINUX_STUBS_I86_H_INCLUDED
#define LINUX_STUBS_I86_H_INCLUDED

#ifndef LINUX_STUBS_REGS_DEFINED
#define LINUX_STUBS_REGS_DEFINED

struct DWORDREGS {
    unsigned int eax, ebx, ecx, edx, esi, edi, cflag, flags;
};

struct WORDREGS {
    unsigned short ax, _hiax;
    unsigned short bx, _hibx;
    unsigned short cx, _hicx;
    unsigned short dx, _hidx;
    unsigned short si, _hisi;
    unsigned short di, _hidi;
    unsigned short cflag, _hicflag;
    unsigned short flags, _hiflags;
};

struct BYTEREGS {
    unsigned char al, ah; unsigned short _hiax;
    unsigned char bl, bh; unsigned short _hibx;
    unsigned char cl, ch; unsigned short _hicx;
    unsigned char dl, dh; unsigned short _hidx;
};

union REGS {
    struct DWORDREGS x;   /* Watcom 32-bit accessor: regs.x.eax, regs.x.cflag */
    struct WORDREGS  w;   /* 16-bit accessor: regs.w.ax */
    struct BYTEREGS  h;   /* 8-bit accessor:  regs.h.al */
};

#endif /* LINUX_STUBS_REGS_DEFINED */

/* Pass-40AL: Watcom DOS interrupt intrinsics — no-op macros. The OK TUs
 * (IPX.CPP, NULLMGR.CPP, IPXMGR.CPP, etc.) get these via FUNCTION.H:272-273
 * gated under #ifdef WIN32 (auto-set by wwstd.h). MPLIB.CPP does NOT include
 * FUNCTION.H or wwstd.h, so the int386 macro never activates there. Provide
 * unconditionally in i86.h (Linux-only shim). #ifndef guard prevents collision
 * with FUNCTION.H's WIN32-gated definition. */
#ifndef int386
#define int386(a,b,c)    0
#endif
#ifndef int386x
#define int386x(a,b,c,d) 0
#endif

#endif /* LINUX_STUBS_I86_H_INCLUDED */

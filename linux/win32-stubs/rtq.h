/* TIM-5 stub: rtq.h — MPath real-time-queue node type.
 * Pass-40AL: MPMGRD.CPP requires a complete type for sizeof(RTQ_NODE)
 * (line 63) and accesses rtqUpCtr (WORD length) and rtqDatum (payload
 * buffer). MPLIB.CPP uses RTQ_NODE only as a pointer return type. */
#ifndef LINUX_STUBS_RTQ_H_INCLUDED
#define LINUX_STUBS_RTQ_H_INCLUDED

struct RTQ_NODE {
    unsigned short rtqUpCtr;        /* send/receive byte-count */
    unsigned char  rtqDatum[62];    /* opaque data payload; sizeof == 64 */
};
typedef struct RTQ_NODE RTQ_NODE;

#endif

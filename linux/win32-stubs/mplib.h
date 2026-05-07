/* TIM-5 stub: mplib.h — Mgen* function declarations for MPMGRD.CPP.
 * Pass-40AL: signatures match MPLIB.CPP definitions exactly. */
#ifndef LINUX_STUBS_MPLIB_H_INCLUDED
#define LINUX_STUBS_MPLIB_H_INCLUDED

#include "rtq.h"

void      Yield(void);
void      PostWindowsMessage(void);
int       MGenGetQueueCtr(int qNo);
int       MGenFlushNodes(int qFrom, int qTo);
int       MGenMCount(unsigned lowerOrderBits, unsigned upperOrderBits);
int       MGenSanityCheck(void);
RTQ_NODE *MGenMoveTo(int qFrom, int qTo);
RTQ_NODE *MGenGetNode(int q);
RTQ_NODE *MGenGetMasterNode(unsigned *size);

#endif

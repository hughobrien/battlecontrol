/* TIM-5 stub: services.h — MPath VxD services declarations.
 * Pass-40AL: MPMGRD.CPP:Find_Num_Connections uses TGAMEDEF and GetGameDef.
 * Only MPLIB.CPP and MPMGRD.CPP include this header (isolated cluster). */
#ifndef LINUX_STUBS_SERVICES_H_INCLUDED
#define LINUX_STUBS_SERVICES_H_INCLUDED

typedef struct {
    int           numPlayers;
    unsigned char _pad[60]; /* opaque; only numPlayers accessed */
} TGAMEDEF;

void GetGameDef(TGAMEDEF *gd, int *sz);

#endif

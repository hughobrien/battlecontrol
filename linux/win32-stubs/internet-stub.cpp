// TIM-153 umbrella-A globals + NOP stubs from INTERNET.CPP and STATS.CPP.
//
// These TUs open with `#ifdef WIN32` before any includes; because wwstd.h
// defines WIN32 only for callers (not for the definition TU itself at file
// scope), the bodies are compiled away.  Provide NOP definitions here using
// primitive types only so no WIN32-specific infrastructure is needed.
//
// When umbrella-A track re-enables these TUs under WIN32, remove this file
// to avoid double-definition.
//
// Data globals — match declared types exactly:
//   INTERNET.H / EXTERNS.H declare the extern shapes.
// Functions — match signatures from INTERNET.H / FUNCTION.H / EXTERNS.H.

// ---- INTERNET.CPP globals ------------------------------------------------
bool GameStatisticsPacketSent = false;
bool ConnectionLost           = false;
bool SpawnedFromWChat         = false;
bool PlanetWestwoodIsHost     = false;
long PlanetWestwoodPortNumber = 1234;
char PlanetWestwoodIPAddress[40] = {};  // IP_ADDRESS_MAX == 40

// ---- STATS.CPP globals ---------------------------------------------------
void *PacketLater = 0;

// ---- INTERNET.CPP functions ----------------------------------------------
void Check_From_WChat(char * /*wchat_name*/)
{
}

// ---- STATS.CPP functions -------------------------------------------------
void Send_Statistics_Packet(void)
{
}

void Register_Game_Start_Time(void)
{
}

void Register_Game_End_Time(void)
{
}

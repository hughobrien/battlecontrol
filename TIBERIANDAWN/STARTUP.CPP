//
// Copyright 2020 Electronic Arts Inc.
//
// TiberianDawn.DLL and RedAlert.dll and corresponding source code is free 
// software: you can redistribute it and/or modify it under the terms of 
// the GNU General Public License as published by the Free Software Foundation, 
// either version 3 of the License, or (at your option) any later version.

// TiberianDawn.DLL and RedAlert.dll and corresponding source code is distributed 
// in the hope that it will be useful, but with permitted additional restrictions 
// under Section 7 of the GPL. See the GNU General Public License in LICENSE.TXT 
// distributed with this program. You should have received a copy of the 
// GNU General Public License along with permitted additional restrictions 
// with this program. If not, see https://github.com/electronicarts/CnC_Remastered_Collection

/* $Header:   F:\projects\c&c\vcs\code\startup.cpv   2.17   16 Oct 1995 16:48:12   JOE_BOSTIC  $ */
/***********************************************************************************************
 ***             C O N F I D E N T I A L  ---  W E S T W O O D   S T U D I O S               ***
 ***********************************************************************************************
 *                                                                                             *
 *                 Project Name : Command & Conquer                                            *
 *                                                                                             *
 *                    File Name : STARTUP.CPP                                                  *
 *                                                                                             *
 *                   Programmer : Joe L. Bostic                                                *
 *                                                                                             *
 *                   Start Date : October 3, 1994                                              *
 *                                                                                             *
 *                  Last Update : August 27, 1995 [JLB]                                        *
 *                                                                                             *
 *---------------------------------------------------------------------------------------------*
 * Functions:                                                                                  *
 *   Delete_Swap_Files -- Deletes previously existing swap files.                              *
 *   Prog_End -- Cleans up library systems in prep for game exit.                              *
 *   main -- Initial startup routine (preps library systems).                                  *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

#include	"function.h"
#include	<conio.h>
#include	<io.h>
#include  "ccdde.h"

bool Read_Private_Config_Struct(char *profile, NewConfigType *config);
void Delete_Swap_Files(void);
void Print_Error_End_Exit(char *string);
void Print_Error_Exit(char *string);
WinTimerClass *WinTimer;
extern void Create_Main_Window ( HANDLE instance , int command_show , int width , int height);

extern bool ReadyToQuit;
void Read_Setup_Options(RawFileClass *config_file);

bool VideoBackBufferAllowed = true;
void Check_From_WChat(char *wchat_name);
bool SpawnedFromWChat = false;
bool ProgEndCalled = false;


extern "C"{
	bool __cdecl Detect_MMX_Availability(void);
	void __cdecl Init_MMX(void);
}



#if (0)
char				WibbleBuffer[1024*1024];

void CD_Test(void)
{
	HANDLE		handle;
	DWORD			size;

	handle= CreateFile("e:\\scores.mix", GENERIC_READ, FILE_SHARE_READ,
												NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);

	if (handle== INVALID_HANDLE_VALUE){
		return;
	}

	unsigned bytes_read;

	do{
		bytes_read = ReadFile (handle , WibbleBuffer , 1024*1024, &size, NULL);

	}while(size == 1024*1024);


	CloseHandle (handle);
}
#endif	//(0)



/***********************************************************************************************
 * main -- Initial startup routine (preps library systems).                                    *
 *                                                                                             *
 *    This is the routine that is first called when the program starts up. It basically        *
 *    handles the command line parsing and setting up library systems.                         *
 *                                                                                             *
 * INPUT:   argc  -- Number of command line arguments.                                         *
 *                                                                                             *
 *          argv  -- Pointer to array of comman line argument strings.                         *
 *                                                                                             *
 * OUTPUT:  Returns with execution failure code (if any).                                      *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   03/20/1995 JLB : Created.                                                                 *
 *=============================================================================================*/

HINSTANCE	ProgramInstance;
extern BOOL CC95AlreadyRunning;
void Move_Point(short &x, short &y, register DirType dir, unsigned short distance);

void Check_Use_Compressed_Shapes (void);
extern void DLL_Shutdown(void);


BOOL WINAPI DllMain(HINSTANCE instance, unsigned int fdwReason, void *lpvReserved)
{
	lpvReserved;

	switch (fdwReason) {
		
		case DLL_PROCESS_ATTACH:
			ProgramInstance = instance;
			break;

		case DLL_PROCESS_DETACH:
			if (WindowsTimer) {
				delete WindowsTimer;
				WindowsTimer = NULL;
			}
			DLL_Shutdown();

			MixFileClass::Free_All();

			Uninit_Game();

			break;
			
		case DLL_THREAD_ATTACH:
		case DLL_THREAD_DETACH:
			break;
	}

	

	return true;
}


//int PASCAL WinMain ( HINSTANCE instance , HINSTANCE , char * command_line , int command_show )
//{
// Heap_Dump_Check( "first thing in main" );
//	malloc(1);

int DLL_Startup(const char * command_line_in)
{
	RunningAsDLL = true;
	int command_show = SW_HIDE;
	HINSTANCE instance = ProgramInstance;
	char command_line[1024];
	strcpy(command_line, command_line_in);

	CCDebugString ("C&C95 - Starting up.\n");


	//WindowsTimer = new WinTimerClass(60,FALSE);
	//CD_Test();



	/*
	** These values return 0x47 if code is working correctly
	*/
//	int temp = Desired_Facing256 (1070, 5419, 1408, 5504);



	/*
	** If we are already running then switch to the existing process and exit
	*/
	SpawnedFromWChat = false;

	if (CC95AlreadyRunning) {	//Set in the DDEServer constructor
		//MessageBox (NULL, "Error - attempt to restart C&C95 when already running.", "Command & Conquer", MB_ICONEXCLAMATION|MB_OK);

		HWND ccwindow;
    	ccwindow = FindWindow ("Command & Conquer", "Command & Conquer");
    	if (ccwindow){
    		SetForegroundWindow ( ccwindow );
    		ShowWindow ( ccwindow, SW_RESTORE );
    	}

		return (EXIT_SUCCESS);
	}

	// ST - 3/6/2019 1:36PM
	//DDSCAPS	surface_capabilities;

	if (Ram_Free(MEM_NORMAL) < 5000000) {
#ifdef GERMAN
		printf("Zuwenig Hauptspeicher verf�gbar.\n");
#else
#ifdef FRENCH
		printf("M�moire vive (RAM) insuffisante.\n");
#else
		printf("Insufficient RAM available.\n");
#endif
#endif
		return(EXIT_FAILURE);
	}


	//void *test_buffer = Alloc(20,MEM_NORMAL);

	//memset ((char*)test_buffer, 0, 21);

	//Free(test_buffer);


	int		argc;				//Command line argument count
	unsigned	command_scan;
	char		command_char;
	char *	argv[20];		//Pointers to command line arguments
	char		path_to_exe[280];

	ProgramInstance = instance;

	/*
	** Get the full path to the .EXE
	*/
	GetModuleFileName (instance, &path_to_exe[0], 280);

	/*
	** First argument is supposed to be a pointer to the .EXE that is running
	**
	*/
	argc=1;							//Set argument count to 1
	argv[0]=&path_to_exe[0];	//Set 1st command line argument to point to full path

	/*
	** Get pointers to command line arguments just like if we were in DOS
	**
	** The command line we get is cr/zero? terminated.
	**
	*/

	command_scan=0;

	do {
		/*
		** Scan for non-space character on command line
		*/
		do {
			command_char = *( command_line+command_scan++ );
		} while ( command_char==' ' );

		if ( command_char!=0 && command_char != 13 ){
			argv[argc++]=command_line+command_scan-1;

			/*
			** Scan for space character on command line
			*/
			bool in_quotes = false;
			do {
				command_char = *( command_line+command_scan++ );
				if (command_char == '"') {
					in_quotes = !in_quotes;
				}
			} while ( (in_quotes || command_char!=' ') && command_char != 0 && command_char!=13 );

		*( command_line+command_scan-1 ) = 0;
		}

	} while ( command_char != 0 && command_char != 13 && argc<20 );



	/*
	**	Remember the current working directory and drive.
	*/
#if (0)	//PG_TO_FIX
	unsigned olddrive;
	char oldpath[MAX_PATH];
	getcwd(oldpath, sizeof(oldpath));
	_dos_getdrive(&olddrive);


	/*
	**	Change directory to the where the executable is located. Handle the
	**	case where there is no path attached to argv[0].
	*/
	char drive[_MAX_DRIVE];
	char path[_MAX_PATH];
	unsigned drivecount;
	_splitpath(argv[0], drive, path, NULL, NULL);
	if (!drive[0]) {
		drive[0] = ('A' + olddrive)-1;
	}
	if (!path[0]) {
		strcpy(path, ".");
	}
	_dos_setdrive(toupper((drive[0])-'A')+1, &drivecount);
	if (path[strlen(path)-1] == '\\') {
		path[strlen(path)-1] = '\0';
	}
	chdir(path);
#endif

#ifdef JAPANESE
	ForceEnglish = false;
#endif
	if (Parse_Command_Line(argc, argv)) {

		WindowsTimer = new WinTimerClass(60,FALSE);
#if (0)
		int time_test = WindowsTimer->Get_System_Tick_Count();
		Sleep (1000);
		if (WindowsTimer->Get_System_Tick_Count() == time_test){
#ifdef FRENCH
			MessageBox(0, "Error - L'horloge syst�me n'a pas pu s'initialiser en raison de l'instabilit� du syt�me. Vous devez red�marrer Windows.",  "Command & Conquer" , MB_OK|MB_ICONSTOP);
#else
#ifdef	GERMAN
			MessageBox(0, "Fehler - das Timer-System konnte aufgrund einer Instabilit�t des Systems nicht initialisiert werden. Bitte starten Sie Windows neu.", "Command & Conquer", MB_OK|MB_ICONSTOP);
#else
			MessageBox(0, "Error - Timer system failed to start due to system instability. You need to restart Windows.", "Command & Conquer", MB_OK|MB_ICONSTOP);
#endif	//GERMAN
#endif	//FRENCH
			return(EXIT_FAILURE);
		}
#endif

		RawFileClass cfile("CONQUER.INI");

#ifdef JAPANESE
	//////////////////////////////////////if(!ForceEnglish) KBLanguage = 1;
#endif


		/*
		** Check for existance of MMX support on the processor
		*/
		if (Detect_MMX_Availability()){
			//MessageBox(NULL, "MMX extensions detected - enabling MMX support.", "Command & Conquer",MB_ICONEXCLAMATION|MB_OK);
			MMXAvailable = true;
		}

		/*
		** If there is loads of memory then use uncompressed shapes
		*/
		Check_Use_Compressed_Shapes();

		/*
		** If there is not enough disk space free, dont allow the product to run.
		*/
		if (Disk_Space_Available() < INIT_FREE_DISK_SPACE) {
#ifdef GERMAN
			char	disk_space_message [512];
			sprintf (disk_space_message, "Nicht genug Festplattenplatz f�r Command & Conquer.\nSie brauchen %d MByte freien Platz auf der Festplatte.", (INIT_FREE_DISK_SPACE) / (1024 * 1024));
			MessageBox(NULL, disk_space_message, "Command & Conquer", MB_ICONEXCLAMATION|MB_OK);
			if ( WindowsTimer )
				delete WindowsTimer;
			return (EXIT_FAILURE);
#endif
#ifdef FRENCH
			char	disk_space_message [512];
			sprintf (disk_space_message, "Espace disque insuffisant pour lancer Command & Conquer.\nVous devez disposer de %d Mo d'espace disponsible sur disque dur.", (INIT_FREE_DISK_SPACE) / (1024 * 1024));
			MessageBox(NULL, disk_space_message, "Command & Conquer", MB_ICONEXCLAMATION|MB_OK);
			if ( WindowsTimer )
				delete WindowsTimer;
			return (EXIT_FAILURE);
#endif
#if !(FRENCH | GERMAN)
			int reply = MessageBox(NULL, "Warning - you are critically low on free disk space for virtual memory and save games. Do you want to play C&C anyway?", "Command & Conquer", MB_ICONQUESTION|MB_YESNO);
			if (reply == IDNO){

				if ( WindowsTimer )
					delete WindowsTimer;
				return (EXIT_FAILURE);
			}

#endif
		}

#if (0)                                 // ST - 1/2/2019 5:50PM
		CDFileClass::Set_CD_Drive (CDList.Get_First_CD_Drive());
#endif
		if (cfile.Is_Available()) {

#ifndef NOMEMCHECK
			char * cdata = (char *)Load_Alloc_Data(cfile);
			Read_Private_Config_Struct(cdata, &NewConfig);
			delete [] cdata;
#else
			Read_Private_Config_Struct((char *)Load_Alloc_Data(cfile), &NewConfig);
#endif
			Read_Setup_Options( &cfile );

			CCDebugString ("C&C95 - Creating main window.\n");

			Create_Main_Window( instance , command_show , ScreenWidth , ScreenHeight );

			CCDebugString ("C&C95 - Initialising audio.\n");

			SoundOn = Audio_Init ( MainWindow , 16 , false , 11025*2 , 0 );

			Palette = new(MEM_CLEAR) unsigned char[768];

			BOOL video_success = FALSE;
			CCDebugString ("C&C95 - Setting video mode.\n");
			/*
			** Set 640x400 video mode. If its not available then try for 640x480
			*/
			if (ScreenHeight == 400){
				if (Set_Video_Mode (MainWindow, ScreenWidth, ScreenHeight, 8)){
					video_success = TRUE;
				}else{
					if (Set_Video_Mode (MainWindow, ScreenWidth, 480, 8)){
						video_success = TRUE;
						ScreenHeight = 480;
					}
				}
			}else{
				if (Set_Video_Mode (MainWindow, ScreenWidth, ScreenHeight, 8)){
					video_success = TRUE;
				}
			}

			if (!video_success){
				CCDebugString ("C&C95 - Failed to set video mode.\n");
				MessageBox(MainWindow, Text_String(TXT_UNABLE_TO_SET_VIDEO_MODE), "Command & Conquer", MB_ICONEXCLAMATION|MB_OK);
				if (WindowsTimer) delete WindowsTimer;
				if (Palette) delete [] Palette;
				return (EXIT_FAILURE);
			}

			CCDebugString ("C&C95 - Initialising video surfaces.\n");

			if (ScreenWidth==320){
				VisiblePage.Init( ScreenWidth , ScreenHeight , NULL , 0 , (GBC_Enum)0);
				ModeXBuff.Init( ScreenWidth , ScreenHeight , NULL , 0 , (GBC_Enum)(GBC_VISIBLE | GBC_VIDEOMEM));
			} else {
				
#if (1)	//ST - 1/3/2019 2:11PM

				/* TIM-343: allocate at 1536×1536 (Remastered logical resolution).
				 * STARTUP.CPP:515 sets ScreenHeight=1536 and the Attach calls below
				 * use 1536×1536 viewport dims.  A 640-wide system-memory buffer
				 * overruns at stride 1536 in Linear_Blit_To_Linear → SIGSEGV. */
				VisiblePage.Init(1536, 1536, NULL, 0, (GBC_Enum)0);
				HiddenPage.Init(1536, 1536, NULL, 0, (GBC_Enum)0);


#else				  
				VisiblePage.Init( ScreenWidth , ScreenHeight , NULL , 0 , (GBC_Enum)(GBC_VISIBLE | GBC_VIDEOMEM));

				/*
				** Check that we really got a video memory page. Failure is fatal.
				*/
				memset (&surface_capabilities, 0, sizeof(surface_capabilities));
				VisiblePage.Get_DD_Surface()->GetCaps(&surface_capabilities);
				if (surface_capabilities.dwCaps & DDSCAPS_SYSTEMMEMORY){
					/*
					** Aaaarrgghh!
					*/
					CCDebugString ("C&C95 - Unable to allocate primary surface.\n");
					MessageBox(MainWindow, Text_String(TXT_UNABLE_TO_ALLOCATE_PRIMARY_VIDEO_BUFFER), "Command & Conquer", MB_ICONEXCLAMATION|MB_OK);
					if (WindowsTimer) delete WindowsTimer;
					if (Palette) delete [] Palette;
					return (EXIT_FAILURE);
				}

				/*
				** If we have enough left then put the hidpage in video memory unless...
				**
				** If there is no blitter then we will get better performance with a system
				** memory hidpage
				**
				** Use a system memory page if the user has specified it via the ccsetup program.
				*/
				CCDebugString ("C&C95 - Allocating back buffer ");
				long video_memory = Get_Free_Video_Memory();
				unsigned video_capabilities = Get_Video_Hardware_Capabilities();
				if (video_memory < ScreenWidth*ScreenHeight ||
						(! (video_capabilities & VIDEO_BLITTER)) ||
						(video_capabilities & VIDEO_NO_HARDWARE_ASSIST) ||
						!VideoBackBufferAllowed){
					CCDebugString ("in system memory.\n");
					HiddenPage.Init (ScreenWidth , ScreenHeight , NULL , 0 , (GBC_Enum)0);
				} else {
					//HiddenPage.Init (ScreenWidth , ScreenHeight , NULL , 0 , (GBC_Enum)0);
					CCDebugString ("in video memory.\n");
					HiddenPage.Init (ScreenWidth , ScreenHeight , NULL , 0 , (GBC_Enum)GBC_VIDEOMEM);

					/*
					** Make sure we really got a video memory hid page. If we didnt then things
					** will run very slowly.
					*/
					memset (&surface_capabilities, 0, sizeof(surface_capabilities));
					HiddenPage.Get_DD_Surface()->GetCaps(&surface_capabilities);
					if (surface_capabilities.dwCaps & DDSCAPS_SYSTEMMEMORY){
						/*
						** Oh dear, big trub. This must be an IBM Aptiva or something similarly cruddy.
						** We must redo the Hidden Page as system memory.
						*/
						AllSurfaces.Remove_DD_Surface(HiddenPage.Get_DD_Surface());  // Remove the old surface from the AllSurfaces list
						HiddenPage.Get_DD_Surface()->Release();
						HiddenPage.Init (ScreenWidth , ScreenHeight , NULL , 0 , (GBC_Enum)0);
					}else{
						VisiblePage.Attach_DD_Surface(&HiddenPage);
					}
				}
#endif
			}
			ScreenHeight = 1536;

			if (VisiblePage.Get_Height() == 480){
				SeenBuff.Attach(&VisiblePage,0, 40, 1536, 1536);
				HidPage.Attach(&HiddenPage, 0, 40, 1536, 1536);
			}else{
				SeenBuff.Attach(&VisiblePage,0, 0, 1536, 1536);
				HidPage.Attach(&HiddenPage, 0, 0, 1536, 1536);
			}
			CCDebugString ("C&C95 - Adjusting variables for resolution.\n");
			Options.Adjust_Variables_For_Resolution();

			CCDebugString ("C&C95 - Setting palette.\n");
			/////////Set_Palette(Palette);

			WindowList[0][WINDOWWIDTH] 	= SeenBuff.Get_Width() >> 3;
			WindowList[0][WINDOWHEIGHT]	= SeenBuff.Get_Height();

			/*
			** Install the memory error handler
			*/
			Memory_Error = &Memory_Error_Handler;

			/*
			** Initialise MMX support if its available
			*/
			CCDebugString ("C&C95 - Entering MMX detection.\n");
			if (MMXAvailable){
				Init_MMX();
			}

			CCDebugString ("C&C95 - Creating mouse class.\n");
			WWMouse = new WWMouseClass(&SeenBuff, 32, 32);
//			MouseInstalled = Install_Mouse(32,24,320,200);
			MouseInstalled = TRUE;

			/*
			** See if we should run the intro
			*/
			CCDebugString ("C&C95 - Reading CONQUER.INI.\n");
			char *buffer = (char*)Alloc(64000 , MEM_NORMAL);		//(char *)HidPage.Get_Buffer();
			cfile.Read(buffer, cfile.Size());
			buffer[cfile.Size()] = '\0';

			/*
			**	Check for forced intro movie run disabling. If the conquer
			**	configuration file says "no", then don't run the intro.
			*/
			char tempbuff[5];
			WWGetPrivateProfileString("Intro", "PlayIntro", "Yes", tempbuff, 4, buffer);
			if ((stricmp(tempbuff, "No") == 0) || SpawnedFromWChat) {
				Special.IsFromInstall = false;
			}else{
				Special.IsFromInstall = true;
			}
			SlowPalette = WWGetPrivateProfileInt("Options", "SlowPalette", 1, buffer);

#ifdef DEMO
			/*
			**	Check for override directory path for CD searches.
			*/
			WWGetPrivateProfileString("CD", "Path", ".", OverridePath, sizeof(OverridePath), buffer);
#endif

			/*
			** Regardless of whether we should run it or not, here we're
			** gonna change it to say "no" in the future.
			*/
			WWWritePrivateProfileString("Intro", "PlayIntro", "No", buffer);
			cfile.Write(buffer, strlen(buffer));

			Free(buffer);

			CCDebugString ("C&C95 - Checking availability of C&CSPAWN.INI packet from WChat.\n");
			if (DDEServer.Get_MPlayer_Game_Info()){
				CCDebugString ("C&C95 - C&CSPAWN.INI packet available.\n");
				Check_From_WChat(NULL);
			}else{
				CCDebugString ("C&C95 - C&CSPAWN.INI packet not arrived yet.\n");
				//Check_From_WChat("C&CSPAWN.INI");
				//if (Special.IsFromWChat){
				//	DDEServer.Disable();
				//}
			}

			/*
			**	If the intro is being run for the first time, then don't
			**	allow breaking out of it with the <ESC> key.
			*/
			if (Special.IsFromInstall) {
				BreakoutAllowed = false;
			}

			Memory_Error_Exit = Print_Error_End_Exit;

			CCDebugString ("C&C95 - Entering main game.\n");
			Main_Game(argc, argv);

			if (RunningAsDLL) {
				return (EXIT_SUCCESS);
			}

			VisiblePage.Clear();
			HiddenPage.Clear();
//			Set_Video_Mode(RESET_MODE);

			Memory_Error_Exit = Print_Error_Exit;

			CCDebugString ("C&C95 - About to exit.\n");
			ReadyToQuit = 1;

			PostMessage(MainWindow, WM_DESTROY, 0, 0);
			do
			{
				Keyboard::Check();
			}while (ReadyToQuit == 1);

			CCDebugString ("C&C95 - Returned from final message loop.\n");
			//Prog_End();
			//Invalidate_Cached_Icons();
			//VisiblePage.Un_Init();
			//HiddenPage.Un_Init();
			//AllSurfaces.Release();
			//Reset_Video_Mode();
			//Stop_Profiler();
			return (EXIT_SUCCESS);

		} else {
#ifdef GERMAN
			puts("Bitte erst das SETUP-Programm starten.\n");
#else
#ifdef FRENCH
			puts("Lancez d'abord le programme de configuration SETUP.\n");
#else
			puts("Run SETUP program first.");
			puts("\n");
#endif
			Kbd.Get();
#endif
		}

//		Remove_Keyboard_Interrupt();
		if (WindowsTimer){
		 	delete WindowsTimer;
		 	WindowsTimer = NULL;
		}

		if (Palette){
			delete [] Palette;
			Palette = NULL;
		}
	}

	/*
	**	Restore the current drive and directory.
	*/
#ifdef NOT_FOR_WIN95
	_dos_setdrive(olddrive, &drivecount);
	chdir(oldpath);
#endif	//NOT_FOR_WIN95

	return(EXIT_SUCCESS);
}


/***********************************************************************************************
 * Prog_End -- Cleans up library systems in prep for game exit.                                *
 *                                                                                             *
 *    This routine should be called before the game terminates. It handles cleaning up         *
 *    library systems so that a graceful return to the host operating system is achieved.      *
 *                                                                                             *
 * INPUT:   none                                                                               *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   03/20/1995 JLB : Created.                                                                 *
 *=============================================================================================*/
void __cdecl Prog_End(const char *why, bool fatal)  // Added why and fatal parameters. ST - 6/27/2019 10:10PM		
{
	GlyphX_Debug_Print("Prog_End()");
	
	if (why) {
		GlyphX_Debug_Print(why);
	}
	if (fatal) {
		*((int*)0) = 0;
	}
	
#ifndef DEMO
	if (GameToPlay == GAME_MODEM || GameToPlay == GAME_NULL_MODEM) {
//		NullModem.Change_IRQ_Priority(0);
	}
#endif
	CCDebugString ("C&C95 - About to call Sound_End.\n");
	Sound_End();
	CCDebugString ("C&C95 - Returned from Sound_End.\n");
	if (WWMouse){
		CCDebugString ("C&C95 - Deleting mouse object.\n");
		delete WWMouse;
		WWMouse = NULL;
	}
	if (WindowsTimer){
		CCDebugString ("C&C95 - Deleting windows timer.\n");
		 delete WindowsTimer;
		 WindowsTimer = NULL;
	}

	if (Palette){
		CCDebugString ("C&C95 - Deleting palette object.\n");
		delete [] Palette;
		Palette = NULL;
	}

	ProgEndCalled = true;
}


/***********************************************************************************************
 * Delete_Swap_Files -- Deletes previously existing swap files.                                *
 *                                                                                             *
 *    This routine will scan through the current directory and delete any swap files it may    *
 *    find. This is used to clear out any left over swap files from previous runs (crashes)    *
 *    of the game. This routine presumes that it cannot delete the swap file that is created   *
 *    by the current run of the game.                                                          *
 *                                                                                             *
 * INPUT:   none                                                                               *
 *                                                                                             *
 * OUTPUT:  none                                                                               *
 *                                                                                             *
 * WARNINGS:   none                                                                            *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *   08/27/1995 JLB : Created.                                                                 *
 *=============================================================================================*/
void Delete_Swap_Files(void)
{
#if (0)
	struct find_t ff;		// for _dos_findfirst

	if (!_dos_findfirst("*.SWP", _A_NORMAL, &ff)) {
		do {
			unlink(ff.name);
		} while(!_dos_findnext(&ff));
	}
#endif
}


void Print_Error_End_Exit(char *string)
{
	printf( "%s\n", string );
	Get_Key();
	Prog_End();
	printf( "%s\n", string );
	if (!RunningAsDLL) {
		exit(1);
	}
}


void Print_Error_Exit(char *string)
{
	printf( "%s\n", string );
	if (!RunningAsDLL) {
		exit(1);
	}
}








/***********************************************************************************************
 * Read_Setup_Options -- Read stuff in from the INI file that we need to know sooner           *
 *                                                                                             *
 *                                                                                             *
 *                                                                                             *
 * INPUT:    Nothing                                                                           *
 *                                                                                             *
 * OUTPUT:   Nothing                                                                           *
 *                                                                                             *
 * WARNINGS: None                                                                              *
 *                                                                                             *
 * HISTORY:                                                                                    *
 *    6/7/96 4:09PM ST : Created                                                               *
 *=============================================================================================*/
void Read_Setup_Options( RawFileClass *config_file )
{
	char *buffer = new char [config_file->Size()];

	if (config_file->Is_Available()){

		config_file->Read (buffer, config_file->Size());

		VideoBackBufferAllowed = WWGetPrivateProfileInt ("Options", "VideoBackBuffer", 1, buffer);
		AllowHardwareBlitFills = WWGetPrivateProfileInt ("Options", "HardwareFills", 1, buffer);
		ScreenHeight = WWGetPrivateProfileInt ("Options", "Resolution", 0, buffer) ? 1536 : 1536;
		IsV107 = WWGetPrivateProfileInt ("Options", "Compatibility", 0, buffer);

		/*
		** See if an alternative socket number has been specified
		*/
		int socket = WWGetPrivateProfileInt ("Options", "Socket", 0, buffer);
		if (socket >0 ){
			socket += 0x4000;
			if (socket >= 0x4000 && socket < 0x8000) {
				Ipx.Set_Socket (socket);
			}
		}

		/*
		** See if a destination network has been specified
		*/
		char netbuf [512];
		memset (netbuf, 0, sizeof (netbuf) );
		char *netptr = WWGetPrivateProfileString ("Options", "DestNet", NULL, netbuf, sizeof (netbuf), buffer);

		if (netptr && strlen (netbuf)){
			NetNumType net;
			NetNodeType node;

			/*
			** Scan the string, pulling off each address piece
			*/
			int i = 0;
			char * p = strtok(netbuf,".");
			int x;
			while (p) {
				sscanf(p,"%x",&x);			// convert from hex string to int
				if (i < 4) {
					net[i] = (char)x;			// fill NetNum
				} else {
					node[i-4] = (char)x;		// fill NetNode
				}
				i++;
				p = strtok(NULL,".");
			}

			/*
			** If all the address components were successfully read, fill in the
			** BridgeNet with a broadcast address to the network across the bridge.
			*/
			if (i >= 4) {
				IsBridge = 1;
				memset(node, 0xff, 6);
				BridgeNet = IPXAddressClass(net, node);
			}
		}

	}

	delete [] buffer;
}


#ifndef _MSC_VER
// TIM-343 pass-99: Linux standalone entry point for the td binary.
//
// Analogous to REDALERT/STARTUP.CPP main() (added in TIM-159 pass-48A).
// Key difference from DLL_Startup: RunningAsDLL is left false so that
// Main_Game drives its own Select_Game/Main_Loop instead of returning
// immediately to an external DLL host after one Select_Game call.

#include <signal.h>
#include <execinfo.h>
#include <unistd.h>

static void td_crash_handler(int sig)
{
    void *buf[64];
    int n = backtrace(buf, 64);
    char **syms = backtrace_symbols(buf, n);
    fprintf(stderr, "\n=== TD CRASH signal %d backtrace ===\n", sig);
    for (int i = 0; i < n; i++)
        fprintf(stderr, "  [%2d] %s\n", i, syms ? syms[i] : "?");
    fflush(stderr);
    signal(sig, SIG_DFL);
    raise(sig);
}

int main(int argc, char * argv[])
{
    signal(SIGSEGV, td_crash_handler);
    signal(SIGABRT, td_crash_handler);
    signal(SIGBUS,  td_crash_handler);

    fprintf(stderr, "[TD] main: entry (RunningAsDLL stays false for standalone run)\n");
    fflush(stderr);

    // RunningAsDLL = false is the default (GLOBALS.CPP); do NOT set true here.
    HINSTANCE instance = ProgramInstance; // null on Linux — stub ignores it
    int command_show = 1;                 // SW_SHOWNORMAL — stub ignores it

    if (Ram_Free(MEM_NORMAL) < 5000000) {
        printf("Insufficient RAM available.\n");
        return EXIT_FAILURE;
    }

    fprintf(stderr, "[TD] Parse_Command_Line\n"); fflush(stderr);
    if (Parse_Command_Line(argc, argv)) {

        fprintf(stderr, "[TD] WinTimerClass\n"); fflush(stderr);
        WindowsTimer = new WinTimerClass(60, FALSE);
        fprintf(stderr, "[TD] WinTimerClass done\n"); fflush(stderr);

        RawFileClass cfile("CONQUER.INI");

        if (cfile.Is_Available()) {
            fprintf(stderr, "[TD] CONQUER.INI found — continuing init\n"); fflush(stderr);

            fprintf(stderr, "[TD] Load_Alloc_Data\n"); fflush(stderr);
#ifndef NOMEMCHECK
            char * cdata = (char *)Load_Alloc_Data(cfile);
            fprintf(stderr, "[TD] Read_Private_Config_Struct\n"); fflush(stderr);
            Read_Private_Config_Struct(cdata, &NewConfig);
            delete [] cdata;
#else
            Read_Private_Config_Struct((char *)Load_Alloc_Data(cfile), &NewConfig);
#endif
            fprintf(stderr, "[TD] Read_Setup_Options\n"); fflush(stderr);
            Read_Setup_Options( &cfile );
            /* TIM-343: Read_Setup_Options hardcodes 1536 (Remastered DLL
             * internal logical resolution). Override to classic 640×480 for
             * standalone Linux binary — same workaround as RA TIM-250 pass-69. */
            ScreenWidth  = 640;
            ScreenHeight = 480;
            fprintf(stderr, "[TD] Read_Setup_Options done; ScreenWidth=%d ScreenHeight=%d\n", ScreenWidth, ScreenHeight); fflush(stderr);

            fprintf(stderr, "[TD] Create_Main_Window (%dx%d)\n", ScreenWidth, ScreenHeight); fflush(stderr);
            Create_Main_Window( instance , command_show , ScreenWidth , ScreenHeight );

            fprintf(stderr, "[TD] Audio_Init\n"); fflush(stderr);
            SoundOn = Audio_Init ( MainWindow , 16 , false , 11025*2 , 0 );

            Palette = new(MEM_CLEAR) unsigned char[768];

            fprintf(stderr, "[TD] Set_Video_Mode %dx%d\n", ScreenWidth, ScreenHeight); fflush(stderr);
            BOOL video_success = Set_Video_Mode (MainWindow, ScreenWidth, ScreenHeight, 8);

            if (!video_success) {
                fprintf(stderr, "[TD] Set_Video_Mode failed\n"); fflush(stderr);
                if (WindowsTimer) delete WindowsTimer;
                if (Palette) delete [] Palette;
                return EXIT_FAILURE;
            }

            /* TIM-343: The 480-case Attach with y=40 requires a buffer at least
             * ScreenHeight+40 rows tall.  On Linux standalone we own the alloc,
             * so just allocate the extra rows and keep the y=40 offset. */
            int phys_height = (ScreenHeight == 480) ? (ScreenHeight + 40) : ScreenHeight;
            VisiblePage.Init( ScreenWidth , phys_height , NULL , 0 , (GBC_Enum)0);
            HiddenPage.Init (ScreenWidth , phys_height , NULL , 0 , (GBC_Enum)0);

            if (VisiblePage.Get_Height() == (480 + 40)){
                SeenBuff.Attach(&VisiblePage,0, 40, ScreenWidth, ScreenHeight);
                HidPage.Attach(&HiddenPage, 0, 40, ScreenWidth, ScreenHeight);
            }else{
                SeenBuff.Attach(&VisiblePage,0, 0, ScreenWidth, ScreenHeight);
                HidPage.Attach(&HiddenPage, 0, 0, ScreenWidth, ScreenHeight);
            }

            /* TIM-453: register HidPage as the SDL present source.
             * GScreenClass::Render writes to HidPage (LogicPage = HidPage).
             * Blit_Display is commented out (remaster DLL path skips it),
             * so SeenBuff/VisiblePage never receives rendered pixels.
             * Wait_Vert_Blank reads from TD_SeenPixels — point it at HidPage
             * so the present pump reads directly from the rendered buffer.
             * stride = Get_Width() + Get_XAdd() is the actual row stride. */
#ifndef _MSC_VER
            {
                extern void SDL_TD_Register_SeenBuff(void*, int, int, int);
                int stride = HidPage.Get_Width() + HidPage.Get_XAdd();
                SDL_TD_Register_SeenBuff(
                    reinterpret_cast<void*>(HidPage.Get_Offset()),
                    HidPage.Get_Width(),
                    HidPage.Get_Height(),
                    stride);
                fprintf(stderr, "[TD] SDL_TD_Register_SeenBuff (HidPage) %dx%d stride=%d\n",
                        HidPage.Get_Width(), HidPage.Get_Height(), stride);
                fflush(stderr);
            }
#endif

            Options.Adjust_Variables_For_Resolution();

            WindowList[0][WINDOWWIDTH]  = SeenBuff.Get_Width() >> 3;
            WindowList[0][WINDOWHEIGHT] = SeenBuff.Get_Height();

            Memory_Error = &Memory_Error_Handler;

            if (MMXAvailable) {
                Init_MMX();
            }

            WWMouse = new WWMouseClass(&SeenBuff, 32, 32);
            MouseInstalled = TRUE;

            char *buffer = (char*)Alloc(64000 , MEM_NORMAL);
            cfile.Read(buffer, cfile.Size());
            buffer[cfile.Size()] = '\0';

            char tempbuff[5];
            WWGetPrivateProfileString("Intro", "PlayIntro", "Yes", tempbuff, 4, buffer);
            if (stricmp(tempbuff, "No") == 0) {
                Special.IsFromInstall = false;
            } else {
                Special.IsFromInstall = true;
            }
            // TIM-695: log so it is clear which branch was taken — Play_Intro
            // is gated on !IsFromInstall (INIT.CPP:598), and an LF-only
            // CONQUER.INI silently falls back to "Yes" via PROFILE.CPP:378.
            fprintf(stderr, "[TD] CONQUER.INI Intro/PlayIntro=[%s] IsFromInstall=%d\n",
                    tempbuff, (int)Special.IsFromInstall); fflush(stderr);

            SlowPalette = WWGetPrivateProfileInt("Options", "SlowPalette", 1, buffer);

            WWWritePrivateProfileString("Intro", "PlayIntro", "No", buffer);
            cfile.Write(buffer, strlen(buffer));
            Free(buffer);

            Memory_Error_Exit = Print_Error_End_Exit;
            fprintf(stderr, "[TD] entering Main_Game\n"); fflush(stderr);
            Main_Game(argc, argv);
            Memory_Error_Exit = Print_Error_Exit;

            fprintf(stderr, "[TD] Main_Game returned\n"); fflush(stderr);

        } else {
            puts("Run SETUP program first.\n");
        }

        if (WindowsTimer) {
            delete WindowsTimer;
            WindowsTimer = NULL;
        }
        if (Palette) {
            delete [] Palette;
            Palette = NULL;
        }
    }

    return EXIT_SUCCESS;
}
#endif  // !_MSC_VER
// TIM-341 pass-98: TiberiaDawn link stubs.
//
// Provides NOP/minimal-viable bodies for every symbol that TIBERIANDAWN/*.CPP
// references but that would normally come from:
//   - TIBERIANDAWN/WIN32LIB/*.CPP  (excluded from the Linux td build)
//   - TIBERIANDAWN/DLLInterface.cpp (excluded: DLL-host entry points)
//   - x86 assembly modules (MMX.ASM, XORDELTA.ASM, ...)
//
// INCLUDE ORDER CAUTION:
//   include-shim/tiberiandawn/ is searched BEFORE include-shim/td-win32lib/.
//   Several headers exist at BOTH the TIBERIANDAWN/ and WIN32LIB/ levels
//   (MOUSE.H, AUDIO.H, DEFINES.H, EXTERNS.H, FUNCTION.H, RAWFILE.H, WWFILE.H).
//   When including the WIN32LIB version, use the explicit "WIN32LIB/<NAME>.H"
//   form so the search finds TIBERIANDAWN/WIN32LIB/<NAME>.H, not the game-
//   level TIBERIANDAWN/<NAME>.H which cascades into the full header chain.

#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <algorithm>
#include <climits>
#include <cstdio>

// TIM-383: SDL2 graphics + input for TiberiaDawn native Linux play.
#ifndef _MSC_VER
#include <SDL2/SDL.h>
#include "sdl_input.h"   // SDL_Process_Input_Events declaration
#include "sdl_window.h"  // SDL_Get_Main_Window / SDL_Set_Main_Window
#endif

// WIN32LIB headers — use explicit "WIN32LIB/" prefix where the header name
// clashes with a TIBERIANDAWN top-level header (e.g. MOUSE.H).
#include "GBUFFER.H"             // GraphicViewPortClass, GraphicBufferClass, LogicPage
#include "TIMER.H"               // TimerClass, CountDownTimerClass, WinTimerClass
#include "WIN32LIB/MOUSE.H"      // WWMouseClass + free mouse declarations
#include "KEYBOARD.H"            // WWKeyboardClass, _Kbd, KN_To_VK, ...
#include "FONT.H"                // FontHeight, FontXSpacing, FontYSpacing, FontPtr
#include "MEMFLAG.H"             // Alloc, Free, MemoryFlagType, Memory_Error, ...
#include "memory.h"              // MemoryClass stub (for MemoryClass::Free body below)
#include "MISC.H"                // SurfaceMonitorClass, AllSurfaces, IRandom, MainWindow
#include "PALETTE.H"             // CurrentPalette, Set_Palette, Fade_Palette_To
#include "ICONCACH.H"            // IconCacheClass, CachedIcons, Is_Icon_Cached
#include "WSA.H"                 // Open_Animation, Close_Animation, Animate_Frame
#include "SHAPE.H"               // Extract_Shape, Extract_Shape_Count
#include "DIPTHONG.H"            // Extract_String
#include "TILE.H"                // Get_Icon_Set_Map
#include "WW_WIN.H"              // Window, Change_Window, Window_Hide_Mouse
#include "CCDDE.H"               // DDEServerClass (TIBERIANDAWN/ level, safe cascade)

// main() is provided by TIBERIANDAWN/STARTUP.CPP (#ifndef _MSC_VER block,
// TIM-343 pass-99). Removed stub from here to avoid duplicate-definition
// link errors now that the real entry point exists in the game source.

// =========================================================================
// TIM-383: SDL2 state (Linux-only) — graphics, palette, input
// =========================================================================
#ifndef _MSC_VER

static SDL_Window*   TD_SDL_Window    = nullptr;
static SDL_Renderer* TD_SDL_Renderer  = nullptr;
// Texture + ARGB surface for indexed→ARGB conversion in the present pump.
static SDL_Texture*  TD_SDL_Texture   = nullptr;
static SDL_Surface*  TD_SDL_ARGB      = nullptr;
static int           TD_SDL_CachedW   = 0;
static int           TD_SDL_CachedH   = 0;
static bool          TD_SDL_FirstPresent = false;
static bool          TD_SDL_QuitRequested = false;
// 256-entry palette populated by Set_DD_Palette; used in Wait_Vert_Blank
// to colour-convert the indexed pixel buffer.
static SDL_Color     TD_SDL_Palette[256] = {};
// Visible pixel buffer registered from STARTUP.CPP after SeenBuff.Attach.
static unsigned char* TD_SeenPixels = nullptr;
static int            TD_SeenW = 0, TD_SeenH = 0, TD_SeenPitch = 0;

extern bool GameInFocus;  // GLOBALS.CPP

// Registration helper: STARTUP.CPP calls this after SeenBuff.Attach so
// Wait_Vert_Blank knows where to read indexed pixels from.
void SDL_TD_Register_SeenBuff(void* pixels, int w, int h, int pitch)
{
    TD_SeenPixels = static_cast<unsigned char*>(pixels);
    TD_SeenW = w; TD_SeenH = h; TD_SeenPitch = pitch;
}

// SDL window-event pump: focus transitions + quit capture.
static void TD_SDL_Process_Window_Events(void)
{
    SDL_PumpEvents();
    SDL_Event ev[16];
    int n;
    do {
        n = SDL_PeepEvents(ev, 16, SDL_GETEVENT, SDL_WINDOWEVENT, SDL_WINDOWEVENT);
        for (int i = 0; i < n; ++i) {
            switch (ev[i].window.event) {
            case SDL_WINDOWEVENT_FOCUS_LOST:
            case SDL_WINDOWEVENT_MINIMIZED:
                AllSurfaces.Set_Surface_Focus(FALSE);
                GameInFocus = false;
                break;
            case SDL_WINDOWEVENT_FOCUS_GAINED:
            case SDL_WINDOWEVENT_RESTORED:
                AllSurfaces.Set_Surface_Focus(TRUE);
                GameInFocus = true;
                break;
            default: break;
            }
        }
    } while (n == 16);
    do {
        n = SDL_PeepEvents(ev, 16, SDL_GETEVENT, SDL_QUIT, SDL_QUIT);
        if (n > 0) TD_SDL_QuitRequested = true;
    } while (n == 16);
}

extern "C" bool SDL_Quit_Requested(void) { return TD_SDL_QuitRequested; }
extern "C" void SDL_Clear_Quit(void)     { TD_SDL_QuitRequested = false; }

// VK_ keysym map — mirrors RA KEY.CPP SDL_Keysym_To_VK exactly.
static unsigned short TD_SDL_Keysym_To_VK(SDL_Keycode k)
{
    if (k >= SDLK_a && k <= SDLK_z) return (unsigned short)(VK_A + (k - SDLK_a));
    if (k >= SDLK_0 && k <= SDLK_9) return (unsigned short)(VK_0 + (k - SDLK_0));
    if (k >= SDLK_F1 && k <= SDLK_F12) return (unsigned short)(VK_F1 + (k - SDLK_F1));
    switch (k) {
    case SDLK_ESCAPE:       return VK_ESCAPE;
    case SDLK_RETURN:
    case SDLK_KP_ENTER:     return VK_RETURN;
    case SDLK_BACKSPACE:    return VK_BACK;
    case SDLK_TAB:          return VK_TAB;
    case SDLK_SPACE:        return VK_SPACE;
    case SDLK_LEFT:         return VK_LEFT;
    case SDLK_RIGHT:        return VK_RIGHT;
    case SDLK_UP:           return VK_UP;
    case SDLK_DOWN:         return VK_DOWN;
    case SDLK_HOME:         return VK_HOME;
    case SDLK_END:          return VK_END;
    case SDLK_PAGEUP:       return VK_PRIOR;
    case SDLK_PAGEDOWN:     return VK_NEXT;
    case SDLK_INSERT:       return VK_INSERT;
    case SDLK_DELETE:       return VK_DELETE;
    case SDLK_LSHIFT:
    case SDLK_RSHIFT:       return VK_SHIFT;
    case SDLK_LCTRL:
    case SDLK_RCTRL:        return VK_CONTROL;
    case SDLK_LALT:
    case SDLK_RALT:         return VK_MENU;
    case SDLK_PAUSE:        return VK_PAUSE;
    case SDLK_CAPSLOCK:     return VK_CAPITAL;
    case SDLK_NUMLOCKCLEAR: return VK_NUMLOCK;
    case SDLK_SCROLLLOCK:   return VK_SCROLL;
    case SDLK_KP_0:         return VK_NUMPAD0;
    case SDLK_KP_1:         return VK_NUMPAD1;
    case SDLK_KP_2:         return VK_NUMPAD2;
    case SDLK_KP_3:         return VK_NUMPAD3;
    case SDLK_KP_4:         return VK_NUMPAD4;
    case SDLK_KP_5:         return VK_NUMPAD5;
    case SDLK_KP_6:         return VK_NUMPAD6;
    case SDLK_KP_7:         return VK_NUMPAD7;
    case SDLK_KP_8:         return VK_NUMPAD8;
    case SDLK_KP_9:         return VK_NUMPAD9;
    case SDLK_KP_PLUS:      return VK_ADD;
    case SDLK_KP_MINUS:     return VK_SUBTRACT;
    case SDLK_KP_MULTIPLY:  return VK_MULTIPLY;
    case SDLK_KP_DIVIDE:    return VK_DIVIDE;
    case SDLK_KP_PERIOD:    return VK_DECIMAL;
    default:                return 0;
    }
}

// SDL cursor position — declared extern "C" in linux/win32-stubs/windows.h
// for GetCursorPos. Updated by the mouse-motion drain below.
extern "C" {
int SDL_Cursor_X = 0;
int SDL_Cursor_Y = 0;
}

// SDL keyboard + mouse drain — called from Wait_Vert_Blank each frame.
// Mirrors RA KEY.CPP SDL_Process_Input_Events.
extern "C" void SDL_Process_Input_Events(void)
{
    if (_Kbd == nullptr) return;
    SDL_PumpEvents();
    SDL_Event ev[16];
    int n;

    // Keyboard
    do {
        n = SDL_PeepEvents(ev, 16, SDL_GETEVENT, SDL_KEYDOWN, SDL_KEYUP);
        for (int i = 0; i < n; ++i) {
            const SDL_KeyboardEvent& ke = ev[i].key;
            unsigned short vk = TD_SDL_Keysym_To_VK(ke.keysym.sym);
            if (vk == 0) continue;
            Uint16 mod = ke.keysym.mod;
            if (mod & KMOD_SHIFT) vk |= WWKEY_SHIFT_BIT;
            if (mod & KMOD_CTRL)  vk |= WWKEY_CTRL_BIT;
            if (mod & KMOD_ALT)   vk |= WWKEY_ALT_BIT;
            if (ev[i].type == SDL_KEYUP) vk |= WWKEY_RLS_BIT;
            vk |= WWKEY_VK_BIT;
            _Kbd->Put((int)vk);
        }
    } while (n == 16);

    // Mouse buttons + motion
    do {
        n = SDL_PeepEvents(ev, 16, SDL_GETEVENT, SDL_MOUSEMOTION, SDL_MOUSEBUTTONUP);
        for (int i = 0; i < n; ++i) {
            Uint32 type = ev[i].type;
            if (type == SDL_MOUSEBUTTONDOWN || type == SDL_MOUSEBUTTONUP) {
                const SDL_MouseButtonEvent& be = ev[i].button;
                unsigned short vk = 0;
                switch (be.button) {
                case SDL_BUTTON_LEFT:   vk = VK_LBUTTON; break;
                case SDL_BUTTON_MIDDLE: vk = VK_MBUTTON; break;
                case SDL_BUTTON_RIGHT:  vk = VK_RBUTTON; break;
                default: continue;
                }
                vk |= WWKEY_VK_BIT;
                if (type == SDL_MOUSEBUTTONUP) vk |= WWKEY_RLS_BIT;
                _Kbd->Put((int)vk);
                _Kbd->Put((int)be.x);
                _Kbd->Put((int)be.y);
            } else if (type == SDL_MOUSEMOTION) {
                SDL_Cursor_X = ev[i].motion.x;
                SDL_Cursor_Y = ev[i].motion.y;
            }
        }
    } while (n == 16);
}

#endif // !_MSC_VER

// =========================================================================
// BufferClass — base buffer class (BUFFER.H; ctors/dtor are non-inline)
// =========================================================================

BufferClass::BufferClass()                  : Buffer(nullptr), Size(0) {}
BufferClass::BufferClass(long size)         : Buffer(std::malloc((size_t)size)), Size(size) {}
BufferClass::BufferClass(void *ptr, long s) : Buffer(ptr), Size(s) {}
BufferClass::~BufferClass()                 { if (Buffer) { std::free(Buffer); Buffer = nullptr; } }

// =========================================================================
// GraphicViewPortClass — video-buffer viewport
// =========================================================================

GraphicViewPortClass::GraphicViewPortClass(
    GraphicBufferClass *graphic_buff, int x, int y, int w, int h)
    : Offset(0), Width(w), Height(h), XAdd(0), XPos(x), YPos(y),
      Pitch(0), GraphicBuff(graphic_buff), IsDirectDraw(FALSE), LockCount(0)
{
    if (graphic_buff) {
        /* Match GBUFFER.CPP Attach: clip to buffer bounds and compute XAdd so
         * that stride = buffer_width always (not viewport width). */
        int bw = graphic_buff->Get_Width();
        int bh = graphic_buff->Get_Height();
        if (x + w > bw) w = bw - x;
        if (y + h > bh) h = bh - y;
        Width  = w;
        Height = h;
        XAdd   = bw - w;
        Offset = (long)(graphic_buff->Get_Offset()) + (long)y * bw + x;
    }
}

GraphicViewPortClass::GraphicViewPortClass()
    : Offset(0), Width(0), Height(0), XAdd(0), XPos(0), YPos(0),
      Pitch(0), GraphicBuff(nullptr), IsDirectDraw(FALSE), LockCount(0)
{}

GraphicViewPortClass::~GraphicViewPortClass() {}

void GraphicViewPortClass::Attach(
    GraphicBufferClass *graphic_buff, int x, int y, int w, int h)
{
    /* Matches GBUFFER.CPP Attach: guard against self-attach, clip to buffer
     * bounds, and use buffer_width as stride so XAdd is consistent. */
    if (this == GraphicBuff) return;
    GraphicBuff = graphic_buff;
    XPos = x; YPos = y;
    XAdd = 0; Pitch = 0; IsDirectDraw = FALSE; LockCount = 0;
    if (graphic_buff) {
        int bw = graphic_buff->Get_Width();
        int bh = graphic_buff->Get_Height();
        if (x + w > bw) w = bw - x;
        if (y + h > bh) h = bh - y;
        XAdd   = bw - w;
        Offset = (long)(graphic_buff->Get_Offset()) + (long)y * bw + x;
    } else {
        Offset = 0;
    }
    Width = w; Height = h;
}

void GraphicViewPortClass::Draw_Rect(
    int /*sx*/, int /*sy*/, int /*dx*/, int /*dy*/, unsigned char /*color*/) {}

HRESULT GraphicViewPortClass::DD_Linear_Blit_To_Linear(
    GraphicViewPortClass & /*dest*/,
    int /*sx*/, int /*sy*/, int /*dx*/, int /*dy*/,
    int /*w*/, int /*h*/, BOOL /*mask*/)
{
    return S_OK;
}

// =========================================================================
// GraphicBufferClass — heap-backed pixel buffer
// =========================================================================
// BufferClass::Buffer and ::Size are `protected` members (BUFFER.H:89-90);
// GraphicBufferClass inherits from BufferClass so can access them directly.

void GraphicBufferClass::Init(int w, int h, void *buffer, long /*size*/, GBC_Enum /*flags*/)
{
    Width        = w;
    Height       = h;
    XAdd         = 0;
    XPos         = 0;
    YPos         = 0;
    Pitch        = 0;
    IsDirectDraw = FALSE;
    LockCount    = 0;
    GraphicBuff  = this;
    VideoSurfacePtr = nullptr;
    if (buffer) {
        Buffer = buffer;
        Size   = (long)w * h;
    } else {
        Buffer = std::malloc((size_t)w * h);
        Size   = (long)w * h;
        if (Buffer) std::memset(Buffer, 0, (size_t)w * h);
    }
    Offset = (long)Buffer;
}

GraphicBufferClass::GraphicBufferClass(int w, int h, GBC_Enum flags)
    : GraphicViewPortClass(), BufferClass()
{
    VideoSurfacePtr = nullptr;
    std::memset(&VideoSurfaceDescription, 0, sizeof(VideoSurfaceDescription));
    Init(w, h, nullptr, (long)w * h, flags);
}

GraphicBufferClass::GraphicBufferClass(int w, int h, void *buffer, long size)
    : GraphicViewPortClass(), BufferClass()
{
    VideoSurfacePtr = nullptr;
    std::memset(&VideoSurfaceDescription, 0, sizeof(VideoSurfaceDescription));
    Init(w, h, buffer, size, (GBC_Enum)0);
}

GraphicBufferClass::GraphicBufferClass(int w, int h, void *buffer)
    : GraphicViewPortClass(), BufferClass()
{
    VideoSurfacePtr = nullptr;
    std::memset(&VideoSurfaceDescription, 0, sizeof(VideoSurfaceDescription));
    Init(w, h, buffer, (long)w * h, (GBC_Enum)0);
}

GraphicBufferClass::GraphicBufferClass()
    : GraphicViewPortClass(), BufferClass()
{
    VideoSurfacePtr = nullptr;
    std::memset(&VideoSurfaceDescription, 0, sizeof(VideoSurfaceDescription));
    Width = Height = 0; Offset = 0; GraphicBuff = this;
}

GraphicBufferClass::~GraphicBufferClass() {}

BOOL GraphicBufferClass::Lock()   { LockCount++; return TRUE; }
BOOL GraphicBufferClass::Unlock() { if (LockCount > 0) LockCount--; return TRUE; }

// =========================================================================
// Global viewport + page variables
// =========================================================================

GraphicViewPortClass *LogicPage    = nullptr;
BOOL AllowHardwareBlitFills        = FALSE;

GraphicViewPortClass *Set_Logic_Page(GraphicViewPortClass *ptr)
{
    GraphicViewPortClass *old = LogicPage; LogicPage = ptr; return old;
}

GraphicViewPortClass *Set_Logic_Page(GraphicViewPortClass &ref)
{
    return Set_Logic_Page(&ref);
}

// =========================================================================
// TimerClass
// =========================================================================

static long _get_ticks()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)(ts.tv_sec * 60L + ts.tv_nsec / 16666667L);
}

TimerClass::TimerClass(BaseTimerEnum /*timer*/, BOOL start)
    : Started(0), Accumulated(0), TickType(BT_SYSTEM)
{
    if (start) Start();
}

long TimerClass::Set(long value, BOOL start)
{
    long old = Time(); Accumulated = value;
    Started = start ? _get_ticks() : 0;
    return old;
}

long TimerClass::Stop()
{
    long t = Time(); Accumulated = t; Started = 0; return t;
}

long TimerClass::Start()
{
    if (!Started) Started = _get_ticks(); return Time();
}

long TimerClass::Time()
{
    return Started ? Accumulated + (_get_ticks() - Started) : Accumulated;
}

long TimerClass::Get_Ticks() { return _get_ticks(); }

// TickCount — free-running 60 Hz counter used throughout the engine.
TimerClass TickCount(BT_SYSTEM, TRUE);

// =========================================================================
// CountDownTimerClass
// =========================================================================

CountDownTimerClass::CountDownTimerClass(BaseTimerEnum timer, long set, int on)
    : TimerClass(timer, on != 0), DelayTime(set)
{
    if (on) TimerClass::Start();
}

CountDownTimerClass::CountDownTimerClass(BaseTimerEnum timer, int on)
    : TimerClass(timer, on != 0), DelayTime(0)
{}

long CountDownTimerClass::Set(long set, BOOL start)
{
    DelayTime = set; TimerClass::Set(0, start); return set;
}

long CountDownTimerClass::Time()
{
    long remaining = DelayTime - TimerClass::Time();
    return (remaining > 0) ? remaining : 0;
}

// =========================================================================
// WinTimerClass
// =========================================================================

// WindowsTimer is defined in GLOBALS.CPP:1025 — no definition here.

WinTimerClass::WinTimerClass(UINT freq, BOOL /*partial*/)
    : TimerHandle(0), Frequency(freq), TrueRate(freq),
      SysTicks(0), UserTicks(0), UserRate(freq)
{
    WindowsTimer = this;
}

WinTimerClass::~WinTimerClass() { if (WindowsTimer == this) WindowsTimer = nullptr; }

// =========================================================================
// WWKeyboardClass
// =========================================================================

WWKeyboardClass::WWKeyboardClass()
    : Head(0), Tail(0), MState(0), Conditional(0), CurrentCursor(nullptr),
      MouseQX(0), MouseQY(0)
{
    std::memset(Buffer,     0, sizeof(Buffer));
    std::memset(ToggleKeys, 0, sizeof(ToggleKeys));
    std::memset(AsciiRemap, 0, sizeof(AsciiRemap));
    std::memset(VKRemap,    0, sizeof(VKRemap));
    _Kbd = this;  // TIM-383: register as the global keyboard instance
}

void  WWKeyboardClass::Clear()  { Head = Tail = 0; }

// TIM-383: real ring-buffer check; called from Check_Key() hot path every frame.
BOOL  WWKeyboardClass::Check()  { return Head != Tail; }

// TIM-383: ring-buffer insertion — same logic as the real KEYBOARD.CPP Put().
BOOL  WWKeyboardClass::Put(int key)
{
    int next = (Tail + 1) & 255;
    if (next == Head) return FALSE;  // buffer full
    Buffer[Tail] = (short)key;
    Tail = next;
    return TRUE;
}

// TIM-383: low-level get; updates MouseQX/Y if mouse key.
int   WWKeyboardClass::Buff_Get(void)
{
    while (!Check()) {}
    int temp = Buffer[Head]; Head = (Head + 1) & 255;
    if (Is_Mouse_Key(temp)) {
        MouseQX = Buffer[Head]; Head = (Head + 1) & 255;
        MouseQY = Buffer[Head]; Head = (Head + 1) & 255;
    }
    return temp;
}

// TIM-383: high-level get; VK bit means no ascii remap needed here.
int   WWKeyboardClass::Get()
{
    int temp = Buff_Get();
    int bits = temp & 0xFF00;
    if (!(bits & WWKEY_VK_BIT)) {
        // ASCII remap: map through AsciiRemap like the real KEYBOARD.CPP.
        // AsciiRemap is zeroed (no Win32 VkKeyScan) so fall back to raw value.
        int asc = AsciiRemap[temp & 0x1FF];
        if (asc) temp = asc | bits;
    }
    return temp;
}

BOOL  WWKeyboardClass::Is_Mouse_Key(int key)
{
    key &= 0xFF;
    return (key == VK_LBUTTON || key == VK_MBUTTON || key == VK_RBUTTON);
}

int   WWKeyboardClass::Check_Num() { return Check() ? (Buffer[Head] & 0xFF) : 0; }
int   WWKeyboardClass::Get_VK()    { return Get() & 0xFF; }
int   WWKeyboardClass::Down(int)   { return 0; }
void  WWKeyboardClass::AI()        {}
void  WWKeyboardClass::Message_Handler(HWND, UINT, UINT, LONG) {}
VOID  WWKeyboardClass::Split(int &key, int &shift, int &ctrl, int &alt, int &rls, int &dbl)
{
    shift = (key & WWKEY_SHIFT_BIT) != 0;
    ctrl  = (key & WWKEY_CTRL_BIT)  != 0;
    alt   = (key & WWKEY_ALT_BIT)   != 0;
    rls   = (key & WWKEY_RLS_BIT)   != 0;
    dbl   = (key & WWKEY_DBL_BIT)   != 0;
    key   = key & 0xFF;
}
int   WWKeyboardClass::Option_On(int)    { return 0; }
int   WWKeyboardClass::Option_Off(int)   { return 0; }
int   WWKeyboardClass::To_ASCII(int key) { return (key & WWKEY_RLS_BIT) ? 0 : key; }
int   WWKeyboardClass::Check_ACII()      { return 0; }
int   WWKeyboardClass::Get_ASCII()       { return 0; }
int   WWKeyboardClass::Check_Bits()      { return 0; }
int   WWKeyboardClass::Get_Bits()        { return 0; }
BOOL  WWKeyboardClass::Put_Key_Message(UINT vk, BOOL release, BOOL /*dbl*/)
{
    int bits = WWKEY_VK_BIT;
    if (release) bits |= WWKEY_RLS_BIT;
    return Put(vk | bits);
}

// _Kbd global pointer (used as _Kbd->Get() etc. throughout engine).
// Set to `this` in the constructor above once Kbd (GLOBALS.CPP) is constructed.
WWKeyboardClass *_Kbd = nullptr;

// Keyboard free functions — C++ linkage (not extern "C").
int  Get_Key()        { return _Kbd ? _Kbd->Get()       : 0; }
int  Get_Key_Num()    { return _Kbd ? _Kbd->Get_VK()    : 0; }
void Clear_KeyBuffer(){ if (_Kbd) _Kbd->Clear(); }
int  Check_Key()      { return _Kbd ? (int)_Kbd->Check() : 0; }
int  Check_Key_Num()  { return _Kbd ? _Kbd->Check_Num() : 0; }
int  Key_Down(int key){ return _Kbd ? _Kbd->Down(key)   : 0; }
int  KN_To_VK(int)   { return 0; }
int  KN_To_KA(int)   { return 0; }

// =========================================================================
// WWMouseClass — WIN32LIB version (from WIN32LIB/MOUSE.H)
// =========================================================================

static int _mouse_state = 0;
static int _mouse_x = 0, _mouse_y = 0;
static WWMouseClass *_mouse_instance = nullptr;

WWMouseClass::WWMouseClass(GraphicViewPortClass *scr, int max_w, int max_h)
    : MouseCursor(nullptr), MouseXHot(0), MouseYHot(0),
      CursorWidth(max_w), CursorHeight(max_h),
      MouseBuffer(nullptr), MouseBuffX(0), MouseBuffY(0),
      MaxWidth(max_w), MaxHeight(max_h),
      MouseCXLeft(0), MouseCYUpper(0), MouseCXRight(0), MouseCYLower(0),
      MCFlags(0), MCCount(0),
      Screen(scr), PrevCursor(nullptr), MouseUpdate(0), State(0),
      EraseBuffer(nullptr), EraseBuffX(0), EraseBuffY(0),
      EraseBuffHotX(0), EraseBuffHotY(0), EraseFlags(0), TimerHandle(0)
{
    std::memset(&MouseCriticalSection, 0, sizeof(MouseCriticalSection));
    _mouse_instance = this;
}

WWMouseClass::~WWMouseClass() { if (_mouse_instance == this) _mouse_instance = nullptr; }

void *WWMouseClass::Set_Cursor(int xh, int yh, void *cursor)
{
    MouseXHot = xh; MouseYHot = yh;
    void *prev = PrevCursor; PrevCursor = (char*)cursor; return prev;
}

void  WWMouseClass::Process_Mouse()                               {}
void  WWMouseClass::Hide_Mouse()                                  { _mouse_state++; }
void  WWMouseClass::Show_Mouse()                                  { if (_mouse_state > 0) _mouse_state--; }
void  WWMouseClass::Conditional_Hide_Mouse(int,int,int,int)       {}
void  WWMouseClass::Conditional_Show_Mouse()                      {}
int   WWMouseClass::Get_Mouse_State()                             { return _mouse_state; }
int   WWMouseClass::Get_Mouse_X()                                 { return _mouse_x; }
int   WWMouseClass::Get_Mouse_Y()                                 { return _mouse_y; }
void  WWMouseClass::Get_Mouse_XY(int &x, int &y)                  { x = _mouse_x; y = _mouse_y; }
void  WWMouseClass::Draw_Mouse(GraphicViewPortClass *)             {}
void  WWMouseClass::Erase_Mouse(GraphicViewPortClass *, int)      {}
void  WWMouseClass::Block_Mouse(GraphicBufferClass *)             {}
void  WWMouseClass::Unblock_Mouse(GraphicBufferClass *)           {}
void  WWMouseClass::Set_Cursor_Clip()                             {}
void  WWMouseClass::Clear_Cursor_Clip()                           {}
void  WWMouseClass::Low_Hide_Mouse()                              {}
void  WWMouseClass::Low_Show_Mouse(int, int)                      {}

// Mouse free functions — C++ linkage (matching WIN32LIB/MOUSE.H declarations).
void  Hide_Mouse()                              { if (_mouse_instance) _mouse_instance->Hide_Mouse(); }
void  Show_Mouse()                              { if (_mouse_instance) _mouse_instance->Show_Mouse(); }
void  Conditional_Hide_Mouse(int x1,int y1,int x2,int y2)
    { if (_mouse_instance) _mouse_instance->Conditional_Hide_Mouse(x1,y1,x2,y2); }
void  Conditional_Show_Mouse()                  { if (_mouse_instance) _mouse_instance->Conditional_Show_Mouse(); }
int   Get_Mouse_State()                         { return _mouse_state; }
int   Get_Mouse_X()                             { return _mouse_x; }
int   Get_Mouse_Y()                             { return _mouse_y; }
void *Set_Mouse_Cursor(int hotx, int hoty, void *cursor)
    { return _mouse_instance ? _mouse_instance->Set_Cursor(hotx, hoty, cursor) : nullptr; }
void  Window_Hide_Mouse(int /*window*/)         { Hide_Mouse(); }
void  Window_Show_Mouse()                       { Show_Mouse(); }

// =========================================================================
// Font globals and functions
// =========================================================================

// FontHeight has C++ linkage in FONT.H (line 106); not inside extern "C".
char FontHeight   = 8;
extern "C" {
int  FontXSpacing = 0;
int  FontYSpacing = 0;
void const *FontPtr = nullptr;
}

void *Set_Font(void const *fontptr)
{
    void const *old = FontPtr; FontPtr = fontptr; return (void*)old;
}

int Char_Pixel_Width(char /*chr*/) { return (int)FontHeight; }

unsigned int String_Pixel_Width(char const *str)
{
    if (!str) return 0;
    return (unsigned int)(std::strlen(str) * FontHeight);
}

void Set_Font_Palette_Range(void const *, INT, INT) {}

// =========================================================================
// Memory management — delegates to C runtime
// =========================================================================

void (*Memory_Error)(void)              = nullptr;
void (*Memory_Error_Exit)(char *string) = nullptr;

void *Alloc(unsigned long bytes_to_alloc, MemoryFlagType /*flags*/)
{
    void *p = std::malloc((size_t)bytes_to_alloc);
    if (!p && Memory_Error) Memory_Error();
    return p;
}

void Free(void const *pointer)                                { std::free(const_cast<void*>(pointer)); }
void *Resize_Alloc(void *original_ptr, unsigned long new_sz) { return std::realloc(original_ptr, (size_t)new_sz); }
long Ram_Free(MemoryFlagType)                                 { return 256L * 1024L * 1024L; }
long Heap_Size(MemoryFlagType)                                { return 256L * 1024L * 1024L; }
long Total_Ram_Free(MemoryFlagType)                           { return 256L * 1024L * 1024L; }

void MemoryClass::Free(void const *p) { std::free(const_cast<void*>(p)); }
MemoryClass Mem;
// GameActive is defined in GLOBALS.CPP:360 — no definition here.

// =========================================================================
// Random-number generation
// =========================================================================

extern "C" unsigned long RandNumb = 0x12349876UL;

unsigned char Random(void)
{
    RandNumb = RandNumb * 2246822519UL + 2654435769UL;
    return (unsigned char)(RandNumb >> 24);
}

int IRandom(int minval, int maxval)
{
    if (minval >= maxval) return minval;
    int range = maxval - minval + 1;
    return minval + (int)(Random() % (unsigned)range);
}

// =========================================================================
// Palette functions
// =========================================================================

extern "C" unsigned char CurrentPalette[768] = {};

void Set_Palette(void *palette)   { if (palette) std::memcpy(CurrentPalette, palette, 768); }

void Fade_Palette_To(void *palette1, unsigned int /*delay*/, void (*callback)())
{
    if (palette1) std::memcpy(CurrentPalette, palette1, 768);
    if (callback) callback();
}

// TIM-383: update both the engine CurrentPalette and the SDL colour table
// used by Wait_Vert_Blank for indexed→ARGB conversion.
extern "C" void Set_DD_Palette(void *palette)
{
    Set_Palette(palette);  // keeps CurrentPalette in sync
#ifndef _MSC_VER
    if (!palette) return;
    const unsigned char* p = static_cast<const unsigned char*>(palette);
    for (int i = 0; i < 256; ++i) {
        TD_SDL_Palette[i].r = (Uint8)((*p++) << 2);
        TD_SDL_Palette[i].g = (Uint8)((*p++) << 2);
        TD_SDL_Palette[i].b = (Uint8)((*p++) << 2);
        TD_SDL_Palette[i].a = 255;
    }
#endif
}

// =========================================================================
// Video mode and vertical blank — TIM-383 SDL2 path
// =========================================================================

BOOL Set_Video_Mode(HWND /*hwnd*/, int w, int h, int /*bpp*/)
{
#ifndef _MSC_VER
    if (TD_SDL_Window != nullptr) return TRUE;  // idempotent

    if (SDL_WasInit(SDL_INIT_VIDEO) == 0) {
        if (SDL_InitSubSystem(SDL_INIT_VIDEO) != 0) {
            fprintf(stderr, "[TD] SDL_InitSubSystem(VIDEO) failed: %s\n", SDL_GetError());
            fflush(stderr);
            return FALSE;
        }
    }
    TD_SDL_Window = SDL_CreateWindow(
        "Tiberian Dawn",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        w, h,
        SDL_WINDOW_HIDDEN);
    if (TD_SDL_Window == nullptr) {
        fprintf(stderr, "[TD] SDL_CreateWindow failed: %s\n", SDL_GetError());
        fflush(stderr);
        return FALSE;
    }
    SDL_Set_Main_Window(TD_SDL_Window);

    // Software renderer: stable under Xvfb (same as RA TIM-250 choice).
    TD_SDL_Renderer = SDL_CreateRenderer(TD_SDL_Window, -1, SDL_RENDERER_SOFTWARE);
    if (TD_SDL_Renderer == nullptr)
        TD_SDL_Renderer = SDL_CreateRenderer(TD_SDL_Window, -1, SDL_RENDERER_ACCELERATED);
    fprintf(stderr, "[TD] SDL window %dx%d renderer=%p\n", w, h, (void*)TD_SDL_Renderer);
    fflush(stderr);
    return TD_SDL_Renderer != nullptr ? TRUE : FALSE;
#else
    return TRUE;
#endif
}

// Called by DDRAW.CPP Reset_Video_Mode path (unused in TD but keeps symmetry).
void Reset_Video_Mode(void)
{
#ifndef _MSC_VER
    if (TD_SDL_Texture) { SDL_DestroyTexture(TD_SDL_Texture); TD_SDL_Texture = nullptr; }
    if (TD_SDL_ARGB)    { SDL_FreeSurface(TD_SDL_ARGB);       TD_SDL_ARGB    = nullptr; }
    if (TD_SDL_Renderer){ SDL_DestroyRenderer(TD_SDL_Renderer); TD_SDL_Renderer = nullptr; }
    if (TD_SDL_Window)  { SDL_DestroyWindow(TD_SDL_Window);   TD_SDL_Window  = nullptr; }
    SDL_Set_Main_Window(nullptr);
    TD_SDL_FirstPresent = false;
    TD_SDL_CachedW = TD_SDL_CachedH = 0;
#endif
}

extern "C" void Wait_Vert_Blank(void)
{
#ifndef _MSC_VER
    // Pump window events (focus/quit) then keyboard+mouse input.
    TD_SDL_Process_Window_Events();
    SDL_Process_Input_Events();

    // Need registered pixel buffer + live renderer to present.
    if (TD_SeenPixels == nullptr || TD_SDL_Renderer == nullptr) return;

    int w = TD_SeenW, h = TD_SeenH;

    // Recreate ARGB intermediate + streaming texture if size changed.
    if (TD_SDL_Texture == nullptr || TD_SDL_ARGB == nullptr ||
        TD_SDL_CachedW != w || TD_SDL_CachedH != h) {
        if (TD_SDL_Texture) { SDL_DestroyTexture(TD_SDL_Texture); TD_SDL_Texture = nullptr; }
        if (TD_SDL_ARGB)    { SDL_FreeSurface(TD_SDL_ARGB);       TD_SDL_ARGB    = nullptr; }
        TD_SDL_Texture = SDL_CreateTexture(TD_SDL_Renderer,
            SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, w, h);
        TD_SDL_ARGB = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
        TD_SDL_CachedW = w; TD_SDL_CachedH = h;
        if (!TD_SDL_Texture || !TD_SDL_ARGB) return;
    }

    // Wrap the registered indexed pixel buffer in a temporary SDL_Surface
    // so SDL_BlitSurface can perform the palette-aware indexed→ARGB conversion.
    SDL_Surface* src = SDL_CreateRGBSurfaceWithFormatFrom(
        TD_SeenPixels, w, h, 8, TD_SeenPitch, SDL_PIXELFORMAT_INDEX8);
    if (!src) return;
    SDL_SetPaletteColors(src->format->palette, TD_SDL_Palette, 0, 256);

    SDL_BlitSurface(src, nullptr, TD_SDL_ARGB, nullptr);
    SDL_FreeSurface(src);

    SDL_UpdateTexture(TD_SDL_Texture, nullptr, TD_SDL_ARGB->pixels, TD_SDL_ARGB->pitch);
    SDL_RenderClear(TD_SDL_Renderer);
    SDL_RenderCopy(TD_SDL_Renderer, TD_SDL_Texture, nullptr, nullptr);
    SDL_RenderPresent(TD_SDL_Renderer);

    if (!TD_SDL_FirstPresent) {
        SDL_ShowWindow(TD_SDL_Window);
        TD_SDL_FirstPresent = true;
        GameInFocus = true;
        // Save first frame for offline verification (mirrors RA TIM-172 pattern).
        int rc = SDL_SaveBMP(TD_SDL_ARGB, "/tmp/td-frame0.bmp");
        fprintf(stderr, "[TD] first SDL frame presented; frame0.bmp rc=%d\n", rc);
        fflush(stderr);
    }
#endif
}

// =========================================================================
// DrawBuff C-callable functions (normally from x86 ASM)
// =========================================================================

extern "C" {

void Buffer_Put_Pixel(void *thisptr, int x, int y, unsigned char color)
{
    auto *vp = (GraphicViewPortClass*)thisptr;
    if (!vp || x < 0 || y < 0 || x >= vp->Get_Width() || y >= vp->Get_Height()) return;
    int stride = vp->Get_Width() + vp->Get_XAdd();
    unsigned char *buf = (unsigned char*)vp->Get_Offset();
    buf[y * stride + x] = color;
}

int Buffer_Get_Pixel(void *thisptr, int x, int y)
{
    auto *vp = (GraphicViewPortClass*)thisptr;
    if (!vp || x < 0 || y < 0 || x >= vp->Get_Width() || y >= vp->Get_Height()) return 0;
    int stride = vp->Get_Width() + vp->Get_XAdd();
    unsigned char *buf = (unsigned char*)vp->Get_Offset();
    return buf[y * stride + x];
}

void Buffer_Clear(void *thisptr, unsigned char color)
{
    auto *vp = (GraphicViewPortClass*)thisptr;
    if (!vp) return;
    int stride = vp->Get_Width() + vp->Get_XAdd();
    unsigned char *buf = (unsigned char*)vp->Get_Offset();
    for (int r = 0; r < vp->Get_Height(); r++)
        std::memset(buf + r * stride, color, vp->Get_Width());
}

VOID Buffer_Draw_Line(void *, int, int, int, int, unsigned char) {}

VOID Buffer_Fill_Rect(void *thisptr, int sx, int sy, int dx, int dy, unsigned char color)
{
    auto *vp = (GraphicViewPortClass*)thisptr;
    if (!vp) return;
    int stride = vp->Get_Width() + vp->Get_XAdd();
    unsigned char *buf = (unsigned char*)vp->Get_Offset();
    int x0 = std::max(sx, 0), x1 = std::min(dx, vp->Get_Width()  - 1);
    int y0 = std::max(sy, 0), y1 = std::min(dy, vp->Get_Height() - 1);
    for (int r = y0; r <= y1; r++)
        std::memset(buf + r * stride + x0, color, (size_t)(x1 - x0 + 1));
}

VOID Buffer_Remap(void *, int, int, int, int, void *) {}

BOOL Linear_Blit_To_Linear(void *thisptr, void *dest,
                             int x_pixel, int y_pixel, int dx_pixel,
                             int dy_pixel, int pixel_width, int pixel_height, BOOL)
{
    auto *src = (GraphicViewPortClass*)thisptr;
    auto *dst = (GraphicViewPortClass*)dest;
    if (!src || !dst) return FALSE;
    int sw = src->Get_Width() + src->Get_XAdd();
    int dw = dst->Get_Width() + dst->Get_XAdd();
    auto *sbuf = (unsigned char*)src->Get_Offset() + y_pixel * sw + x_pixel;
    auto *dbuf = (unsigned char*)dst->Get_Offset() + dy_pixel * dw + dx_pixel;
    int w = std::min(pixel_width,  std::min(src->Get_Width()  - x_pixel, dst->Get_Width()  - dx_pixel));
    int h = std::min(pixel_height, std::min(src->Get_Height() - y_pixel, dst->Get_Height() - dy_pixel));
    if (w <= 0 || h <= 0) return TRUE;
    for (int r = 0; r < h; r++) std::memcpy(dbuf + r * dw, sbuf + r * sw, (size_t)w);
    return TRUE;
}

BOOL Linear_Scale_To_Linear(void *, void *, int, int, int, int, int, int, int, int, BOOL, char *) { return FALSE; }
long Buffer_To_Page(int, int, int, int, void *, void *) { return 0; }
void Buffer_Draw_Stamp(void const *, void const *, int, int, int, void const *) {}
void Buffer_Draw_Stamp_Clip(void const *, void const *, int, int, int, void const *, int, int, int, int) {}
unsigned long LCW_Uncompress(void *, void *, unsigned long) { return 0; }
unsigned int Apply_XOR_Delta(char *, char *) { return 0; }
void Apply_XOR_Delta_To_Page_Or_Viewport(void *, void *, int, int, int) {}

// DRAWBUFF.H declares these in extern "C" (called from inline GBUFFER.H methods).
long Buffer_To_Buffer(void *, int, int, int, int, void *, long) { return 0; }
LONG Buffer_Print(void *, const char *, int, int, int, int)     { return 0; }

// FUNCTION.H declares Buffer_Frame_To_Page in extern "C".
long Buffer_Frame_To_Page(int x, int y, int w, int h,
                          void *src, GraphicViewPortClass &dest, int flags, ...)
{
    if (!src || w <= 0 || h <= 0) return 0;
    const unsigned char *pixels = (const unsigned char*)src;
    if (flags & 0x0020) { x -= w / 2; y -= h / 2; }
    int vw = dest.Get_Width(), vh = dest.Get_Height();
    int stride = vw + dest.Get_XAdd();
    int sx0 = 0, sy0 = 0, dw = w, dh = h;
    if (x < 0)       { sx0 = -x;    dw += x;    x = 0; }
    if (y < 0)       { sy0 = -y;    dh += y;    y = 0; }
    if (x + dw > vw) { dw = vw - x; }
    if (y + dh > vh) { dh = vh - y; }
    if (dw <= 0 || dh <= 0) return 0;
    auto *dst_base = (unsigned char*)dest.Get_Offset();
    const bool trans = (flags & 0x0040) != 0;
    for (int row = 0; row < dh; row++) {
        const unsigned char *srow = pixels + (sy0 + row) * w + sx0;
        unsigned char       *drow = dst_base + (y + row) * stride + x;
        if (trans) { for (int col = 0; col < dw; col++) if (srow[col]) drow[col] = srow[col]; }
        else        std::memcpy(drow, srow, (size_t)dw);
    }
    return 1;
}

}  // extern "C"

// =========================================================================
// IFF / shape / uncompress functions
// =========================================================================

unsigned long Uncompress_Data(void const *, void *) { return 0; }
unsigned long Load_Uncompress(char const *, BufferClass &, BufferClass &, void *) { return 0; }
void *Extract_Shape(void const *, int)         { return nullptr; }
int   Extract_Shape_Count(void const *)         { return 0; }
// TIM-362: real implementation from TIBERIANDAWN/WIN32LIB/DIPTHONG.CPP.
// The null stub caused vsprintf(buf, nullptr, args) SIGSEGV in Fancy_Text_Print
// whenever Do_Win called Text_String(TXT_MISSION) / Text_String(TXT_SCENARIO_WON).
char *Extract_String(void const *data, int string)
{
    if (!data || string < 0) return nullptr;
    // Internet/multiplayer string range (indices 4567+) are inline literals.
    // The standard CONQUER.ENG file only covers indices 0..4566.
    if (string >= 4567) return nullptr;
    // Layout: table of uint16 offsets followed by packed string bytes.
    // ptr[string] is the byte offset from the start of the block to the string.
    unsigned short const *ptr = static_cast<unsigned short const *>(data);
    return const_cast<char *>(static_cast<char const *>(data) + ptr[string]);
}
void *Get_Icon_Set_Map(void const *)            { return nullptr; }
void *Build_Fading_Table(void const *, void const *, long int, long int) { return nullptr; }

extern "C" {
int Clip_Rect(int *x, int *y, int *dw, int *dh, int w, int h)
{
    if (!x || !y || !dw || !dh) return -1;
    if (*x < 0)        { *dw += *x; *x = 0; }
    if (*y < 0)        { *dh += *y; *y = 0; }
    if (*x + *dw > w)  *dw = w - *x;
    if (*y + *dh > h)  *dh = h - *y;
    return (*dw <= 0 || *dh <= 0) ? -1 : 0;
}
int Confine_Rect(int *x, int *y, int dw, int dh, int w, int h)
{
    if (!x || !y) return 0;
    if (*x + dw > w) *x = w - dw;
    if (*y + dh > h) *y = h - dh;
    if (*x < 0) *x = 0;
    if (*y < 0) *y = 0;
    return 0;
}
}  // extern "C"

// =========================================================================
// WSA animation
// =========================================================================

void *Open_Animation(char const *, char *, long, WSAOpenType, unsigned char *) { return nullptr; }
void  Close_Animation(void *) {}
BOOL  Animate_Frame(void *, GraphicViewPortClass &, int, int, int, WSAType, void *, void *) { return FALSE; }
int   Get_Animation_Frame_Count(void *) { return 0; }

// =========================================================================
// Icon cache
// =========================================================================

IconCacheClass CachedIcons[MAX_CACHED_ICONS];
int  CachedIconsDrawn   = 0;
int  UnCachedIconsDrawn = 0;
BOOL IconCacheAllowed = FALSE;  // GBUFFER.H declares as C++ linkage BOOL

IconCacheClass::IconCacheClass()
    : TimesDrawn(0), TimesFailed(0),
      CacheSurface(nullptr), IsCached(FALSE), SurfaceLost(FALSE),
      DrawFrequency(0), IconSource(nullptr)
{}

IconCacheClass::~IconCacheClass() {}
void IconCacheClass::Restore()                 {}
BOOL IconCacheClass::Cache_It(void *)          { return FALSE; }
void IconCacheClass::Uncache_It()              {}
void IconCacheClass::Draw_It(LPDIRECTDRAWSURFACE, int, int, int, int, int, int) {}
// Get_Is_Cached is defined inline in ICONCACH.H; no body here.

void Invalidate_Cached_Icons()                 {}
void Restore_Cached_Icons()                    {}
void Register_Icon_Set(void *, BOOL)           {}

extern "C" {
void Clear_Icon_Pointers()                          {}
void Cache_Copy_Icon(void const *, void *, int)     {}
int  Is_Icon_Cached(void const *, int)              { return 0; }
int  Get_Icon_Index(void *)                         { return 0; }
int  Get_Free_Index()                               { return -1; }
BOOL Cache_New_Icon(int, void *)                    { return FALSE; }
int  Get_Free_Cache_Slot()                          { return -1; }
}

// =========================================================================
// SurfaceMonitorClass
// =========================================================================

SurfaceMonitorClass::SurfaceMonitorClass() : SurfacesRestored(FALSE), InFocus(FALSE)
{ std::memset(Surface, 0, sizeof(Surface)); }

void SurfaceMonitorClass::Add_DD_Surface(LPDIRECTDRAWSURFACE)          {}
void SurfaceMonitorClass::Remove_DD_Surface(LPDIRECTDRAWSURFACE)       {}
BOOL SurfaceMonitorClass::Got_Surface_Already(LPDIRECTDRAWSURFACE)     { return FALSE; }
void SurfaceMonitorClass::Restore_Surfaces()                           {}
void SurfaceMonitorClass::Set_Surface_Focus(BOOL in_focus)             { InFocus = in_focus; }
void SurfaceMonitorClass::Release()                                    {}

SurfaceMonitorClass AllSurfaces;
BOOL OverlappedVideoBlits = FALSE;

// =========================================================================
// Win32 window / global variables
// =========================================================================

HWND MainWindow = nullptr;
extern "C" { int TotalLocks = 0; }
unsigned int Window = 0;
int Change_Window(int windnum) { int old = (int)Window; Window = (unsigned)windnum; return old; }

// =========================================================================
// MMX / x86 ASM stubs
// =========================================================================

extern "C" {
void Init_MMX(void)                { }
int  Detect_MMX_Availability(void) { return 0; }
// Stop_Execution: x86 halt routine; NOP body (stop-execution-stub.cpp excluded).
void Stop_Execution(void)          { }
}

// GetSystemTimeAsFileTime is in kernel32-stub.cpp — no definition here.

// =========================================================================
// SDL_Window_Show / SDL_Window_Raise (declared in windows.h stub)
// TIM-383: real implementations routed through TD_SDL_Window.
// =========================================================================

extern "C" {
void SDL_Window_Show(int sw_command)
{
#ifndef _MSC_VER
    if (!TD_SDL_Window) return;
    switch (sw_command) {
    case 0:                    SDL_HideWindow(TD_SDL_Window); break;
    case 2: case 6: case 7:   SDL_MinimizeWindow(TD_SDL_Window); break;
    case 3:                    SDL_MaximizeWindow(TD_SDL_Window);
                               SDL_ShowWindow(TD_SDL_Window); break;
    default:                   SDL_ShowWindow(TD_SDL_Window); break;
    }
#endif
}

void SDL_Window_Raise(void)
{
#ifndef _MSC_VER
    if (TD_SDL_Window) SDL_RaiseWindow(TD_SDL_Window);
#endif
}
}

// =========================================================================
// Misc engine globals
// =========================================================================

WORD Hard_Error_Occured             = 0;
// CC95AlreadyRunning, DDEServer, DDEServerClass methods, and
// Send_Data_To_DDE_Server are now defined in CCDDE.CPP (WIN32=1 makes the
// #ifdef WIN32 body active). Removed stubs to avoid ODR multiple-definition.
int  GlyphXClientSidebarWidthInLeptons = 0;
bool ShareAllyVisibility            = false;

// =========================================================================
// Instance_Class — Win32 DDE wrapper (DDE.H / CCDDE.CPP).
// TIM-343: globally-defined WIN32=1 causes CCDDE.CPP to compile the DDE
// code path, requiring Instance_Class bodies. Stub everything NOP; TD on
// Linux doesn't talk to WChat.
// =========================================================================
DWORD Instance_Class::id_inst      = 0;
BOOL  Instance_Class::process_pokes = FALSE;
char  Instance_Class::ascii_name[32] = {};
BOOL (*Instance_Class::callback)(LPBYTE, long) = nullptr;

Instance_Class::Instance_Class(LPSTR, LPSTR) : dde_error(TRUE) {}
Instance_Class::~Instance_Class() {}
BOOL Instance_Class::Enable_Callback(BOOL)          { return FALSE; }
BOOL Instance_Class::Test_Server_Running(HSZ)        { return FALSE; }
BOOL Instance_Class::Open_Poke_Connection(HSZ)       { return FALSE; }
BOOL Instance_Class::Close_Poke_Connection()         { return FALSE; }
BOOL Instance_Class::Poke_Server(LPBYTE, DWORD)      { return FALSE; }
BOOL Instance_Class::Register_Server(BOOL (CALLBACK *)(LPBYTE, long)) { return FALSE; }
HDDEDATA CALLBACK Instance_Class::dde_callback(UINT, UINT, HCONV, HSZ, HSZ, HDDEDATA, DWORD, DWORD) { return nullptr; }

// =========================================================================
// DLL / GlyphX callback stubs
// (Called from TD engine into the DLL host; NOP for standalone Linux binary.)
// =========================================================================

// Forward-declare types used only in signatures; real definitions are in
// TIBERIANDAWN headers that we deliberately do not pull in here.
class HouseClass;
class ObjectClass;
enum  ThemeType : int;
enum  EventCallbackMessageEnum : int;
class FileClass;
class SidebarGlyphxClass;

void GlyphX_Debug_Print(const char *) {}
void GlyphX_Assign_Houses(void)       {}
void Play_Movie_GlyphX(const char *, ThemeType) {}

void On_Achievement_Event(const HouseClass *, const char *, const char *) {}
void On_Sound_Effect(int, int, unsigned long)                             {}
void On_Speech(int, HouseClass *)                                         {}
void On_Ping(HouseClass const *, unsigned long)                           {}
void On_Message(const char *, float, long long)                           {}
void On_Defeated_Message(const char *, float)                             {}

void DLL_Shutdown(void)                                                   {}
void DLL_Draw_Intercept(int,int,int,int,int,int,ObjectClass*,const char*,char,int) {}
void DLL_Draw_Pip_Intercept(ObjectClass const *, int)                     {}
void DLL_Draw_Line_Intercept(int,int,int,int,unsigned char,int)           {}
bool DLL_Export_Get_Input_Key_State(int)                                  { return false; }
void DLL_Code_Pointers(void)                                              {}
void DLL_Decode_Pointers(void)                                            {}
bool DLLLoad(FileClass &)                                                 { return false; }
bool DLLSave(FileClass &)                                                 { return false; }

SidebarGlyphxClass *Get_Current_Context_Sidebar(HouseClass *)             { return nullptr; }
void Logic_Switch_Player_Context(HouseClass *)                            {}
void Recalculate_Placement_Distances()                                    {}

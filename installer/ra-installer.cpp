// Red Alert Linux Installer
// Reproduces the Westwood Studios Windows 95-era setup experience using SDL2.
//
// Assets used:
//   ~/redalert/CD1/PLANETWW/SETUP.BMP   — splash background (shipped with CD1)
//
// Build:  see installer/CMakeLists.txt
// Run:    ./ra-setup [destination-dir]

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <SDL2/SDL_image.h>

#include <string>
#include <vector>
#include <fstream>
#include <filesystem>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

namespace fs = std::filesystem;

// ---------- constants ----------

static constexpr int WIN_W = 640;
static constexpr int WIN_H = 480;

// Win95 palette
static const SDL_Color C_BG        = {192, 192, 192, 255};
static const SDL_Color C_NAVY      = {  0,   0, 128, 255};
static const SDL_Color C_WHITE     = {255, 255, 255, 255};
static const SDL_Color C_BLACK     = {  0,   0,   0, 255};
static const SDL_Color C_GRAY_LT   = {224, 224, 224, 255};
static const SDL_Color C_GRAY_DK   = {128, 128, 128, 255};
static const SDL_Color C_GRAY_DDK  = { 64,  64,  64, 255};
static const SDL_Color C_PROGRESS  = {  0,   0, 128, 255};
static const SDL_Color C_PROG_BG   = {255, 255, 255, 255};
static const SDL_Color C_INPUT_BG  = {255, 255, 255, 255};
static const SDL_Color C_RA_RED    = {204,   0,   0, 255};

// ---------- renderer helpers ----------

static void fill(SDL_Renderer* r, SDL_Color c, SDL_Rect rect) {
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
    SDL_RenderFillRect(r, &rect);
}

static void hline(SDL_Renderer* r, SDL_Color c, int x, int y, int len) {
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
    SDL_RenderDrawLine(r, x, y, x + len - 1, y);
}

static void vline(SDL_Renderer* r, SDL_Color c, int x, int y, int len) {
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
    SDL_RenderDrawLine(r, x, y, x, y + len - 1);
}

// Win95 raised 3-D bevel
static void bevel_raised(SDL_Renderer* r, int x, int y, int w, int h) {
    hline(r, C_WHITE,    x,     y,     w);
    vline(r, C_WHITE,    x,     y,     h);
    hline(r, C_GRAY_LT,  x + 1, y + 1, w - 2);
    vline(r, C_GRAY_LT,  x + 1, y + 1, h - 2);
    hline(r, C_GRAY_DDK, x,     y + h - 1, w);
    vline(r, C_GRAY_DDK, x + w - 1, y, h);
    hline(r, C_GRAY_DK,  x + 1, y + h - 2, w - 2);
    vline(r, C_GRAY_DK,  x + w - 2, y + 1, h - 2);
}

// Win95 sunken inset
static void bevel_sunken(SDL_Renderer* r, int x, int y, int w, int h) {
    hline(r, C_GRAY_DK,  x,     y,     w);
    vline(r, C_GRAY_DK,  x,     y,     h);
    hline(r, C_GRAY_DDK, x + 1, y + 1, w - 2);
    vline(r, C_GRAY_DDK, x + 1, y + 1, h - 2);
    hline(r, C_WHITE,    x,     y + h - 1, w);
    vline(r, C_WHITE,    x + w - 1, y, h);
    hline(r, C_GRAY_LT,  x + 1, y + h - 2, w - 2);
    vline(r, C_GRAY_LT,  x + w - 2, y + 1, h - 2);
}

static void draw_text(SDL_Renderer* r, TTF_Font* f, const char* s, SDL_Color c, int x, int y) {
    if (!s || !s[0]) return;
    SDL_Surface* surf = TTF_RenderUTF8_Blended(f, s, c);
    if (!surf) return;
    SDL_Texture* tex = SDL_CreateTextureFromSurface(r, surf);
    SDL_Rect dst = {x, y, surf->w, surf->h};
    SDL_FreeSurface(surf);
    if (!tex) return;
    SDL_RenderCopy(r, tex, nullptr, &dst);
    SDL_DestroyTexture(tex);
}

static int text_w(TTF_Font* f, const char* s) {
    int w = 0, h = 0;
    TTF_SizeUTF8(f, s, &w, &h);
    return w;
}

// Draw a Win95-style push button; returns its SDL_Rect for hit-testing
static SDL_Rect draw_button(SDL_Renderer* r, TTF_Font* f, const char* label,
                            int x, int y, int w, int h, bool pressed = false) {
    fill(r, C_BG, {x, y, w, h});
    if (pressed) {
        bevel_sunken(r, x, y, w, h);
        x += 1; y += 1;
    } else {
        bevel_raised(r, x, y, w, h);
    }
    int tw = text_w(f, label);
    int th = TTF_FontHeight(f);
    draw_text(r, f, label, C_BLACK, x + (w - tw) / 2, y + (h - th) / 2);
    return {x, y, w, h};
}

// Draw a Win95 window/dialog box (background + title bar). Returns content rect.
static SDL_Rect draw_dialog(SDL_Renderer* r, TTF_Font* title_f, const char* title,
                            int x, int y, int w, int h) {
    fill(r, C_BG, {x, y, w, h});
    bevel_raised(r, x, y, w, h);
    // title bar
    int tb_h = 22;
    fill(r, C_NAVY, {x + 2, y + 2, w - 4, tb_h});
    draw_text(r, title_f, title, C_WHITE, x + 8, y + 4);
    // close button (decorative)
    int cbx = x + w - 20, cby = y + 3;
    fill(r, C_BG, {cbx, cby, 16, 16});
    bevel_raised(r, cbx, cby, 16, 16);
    draw_text(r, title_f, "X", C_BLACK, cbx + 4, cby + 2);
    return {x + 4, y + tb_h + 4, w - 8, h - tb_h - 8};
}

// Red Alert branded header strip inside a dialog
static void draw_ra_header(SDL_Renderer* r, TTF_Font* bold_f, TTF_Font* small_f,
                           int x, int y, int w) {
    // Dark background strip
    fill(r, {20, 20, 20, 255}, {x, y, w, 46});
    // Red left accent
    fill(r, C_RA_RED, {x, y, 6, 46});
    draw_text(r, bold_f,  "Command & Conquer",  C_RA_RED,   x + 14, y + 4);
    draw_text(r, small_f, "Red Alert",          C_WHITE,    x + 14, y + 24);
    draw_text(r, small_f, "Setup",              C_GRAY_DK,  x + 76, y + 24);
}

// Progress bar
static void draw_progress(SDL_Renderer* r, float pct, int x, int y, int w, int h) {
    bevel_sunken(r, x - 2, y - 2, w + 4, h + 4);
    fill(r, C_PROG_BG, {x, y, w, h});
    int filled = (int)(pct * w);
    if (filled > 0) {
        fill(r, C_PROGRESS, {x, y, filled, h});
        // Classic segmented appearance
        SDL_SetRenderDrawColor(r, 0, 0, 160, 255);
        for (int bx = x + 3; bx < x + filled; bx += 8)
            SDL_RenderDrawLine(r, bx, y, bx, y + h - 1);
    }
}

// Horizontal separator rule
static void separator(SDL_Renderer* r, int x, int y, int w) {
    hline(r, C_GRAY_DK, x, y,     w);
    hline(r, C_WHITE,   x, y + 1, w);
}

// ---------- stage machinery ----------

enum class Stage { SPLASH, WELCOME, DEST_DIR, INSTALLING, COMPLETE };

struct App {
    SDL_Renderer* ren = nullptr;
    TTF_Font* f_bold   = nullptr;   // 15pt bold — dialog titles, logo
    TTF_Font* f_body   = nullptr;   // 13pt regular — body text
    TTF_Font* f_small  = nullptr;   // 11pt regular — captions, path box

    SDL_Texture* splash_tex = nullptr;
    int splash_w = 0, splash_h = 0;

    Stage stage = Stage::SPLASH;
    Uint32 stage_ts = 0;

    std::string dest;       // install destination
    float  progress = 0.f;
    bool   installed = false;
};

// Files to animate during installation
static const std::vector<const char*> INSTALL_FILES = {
    "MAIN.MIX", "REDALERT.MIX", "HIRES.MIX", "LORES.MIX",
    "LOCAL.MIX", "GENERAL.MIX", "SOUNDS.MIX", "SPEECH.MIX",
    "MOVIES1.MIX", "MOVIES2.MIX", "SETUP.EXE", "REDALERT.INI",
    "README.TXT", "RA.EXE",
};
static const float INSTALL_DURATION_S = 4.5f;

// Write launcher script and mark install complete
static void do_install(const std::string& dest) {
    std::error_code ec;
    fs::create_directories(dest, ec);   // ensure destination exists
    std::string script = dest + "/run-redalert.sh";
    std::ofstream f(script);
    if (!f) return;
    f << "#!/usr/bin/env bash\n"
      << "# Red Alert Linux Launcher — generated by ra-setup\n"
      << "GAME_DIR=\"" << dest << "\"\n"
      << "# Find the compiled binary relative to this script\n"
      << "SCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
      << "BINARY=\"$SCRIPT_DIR/../../build/redalert.elf\"\n"
      << "if [[ ! -x \"$BINARY\" ]]; then\n"
      << "    # Fallback: search common locations\n"
      << "    for p in \\\n"
      << "        \"$SCRIPT_DIR/../build/redalert.elf\" \\\n"
      << "        \"$(dirname \"$SCRIPT_DIR\")/build/redalert.elf\"; do\n"
      << "        if [[ -x \"$p\" ]]; then BINARY=\"$p\"; break; fi\n"
      << "    done\n"
      << "fi\n"
      << "cd \"$GAME_DIR\" && exec \"$BINARY\" \"$@\"\n";
    f.close();
    chmod(script.c_str(), 0755);
}

// ---------- per-stage renderers ----------

// Returns true when stage should advance
static bool stage_splash(App& app, bool any_input) {
    SDL_Renderer* r = app.ren;

    if (app.splash_tex) {
        // Scale-fit to window keeping aspect ratio
        float sx = (float)WIN_W / app.splash_w;
        float sy = (float)WIN_H / app.splash_h;
        float s  = std::max(sx, sy);
        int dw = (int)(app.splash_w * s), dh = (int)(app.splash_h * s);
        int dx = (WIN_W - dw) / 2, dy = (WIN_H - dh) / 2;
        SDL_Rect dst = {dx, dy, dw, dh};
        SDL_RenderCopy(r, app.splash_tex, nullptr, &dst);
    } else {
        fill(r, {10, 10, 10, 255}, {0, 0, WIN_W, WIN_H});
    }

    // Overlay strip at the bottom
    fill(r, {0, 0, 0, 200}, {0, WIN_H - 80, WIN_W, 80});
    fill(r, C_RA_RED, {0, WIN_H - 80, 8, 80});
    draw_text(r, app.f_bold,  "Red Alert Setup",             C_WHITE,   16, WIN_H - 72);
    draw_text(r, app.f_body,  "Westwood Studios, Inc.",      C_GRAY_DK, 16, WIN_H - 50);
    draw_text(r, app.f_small, "Click anywhere to continue",  C_GRAY_DK, 16, WIN_H - 26);

    Uint32 elapsed = SDL_GetTicks() - app.stage_ts;
    return any_input || elapsed > 3500;
}

static bool stage_welcome(App& app, bool next) {
    SDL_Renderer* r = app.ren;
    fill(r, C_BG, {0, 0, WIN_W, WIN_H});

    int dx = 80, dy = 50, dw = 480, dh = 380;
    SDL_Rect content = draw_dialog(r, app.f_bold, "Red Alert Setup", dx, dy, dw, dh);
    int cx = content.x, cy = content.y;

    draw_ra_header(r, app.f_bold, app.f_body, cx, cy, content.w);
    cy += 56;

    draw_text(r, app.f_body, "Welcome to the Red Alert Setup program.",              C_BLACK, cx + 8, cy); cy += 22;
    draw_text(r, app.f_body, "This program installs Red Alert on your computer.",    C_BLACK, cx + 8, cy); cy += 36;
    draw_text(r, app.f_body, "This program is protected by copyright law and",       C_BLACK, cx + 8, cy); cy += 20;
    draw_text(r, app.f_body, "international treaties.",                               C_BLACK, cx + 8, cy); cy += 36;
    draw_text(r, app.f_body, "To install Red Alert, click Next.",                    C_BLACK, cx + 8, cy); cy += 20;
    draw_text(r, app.f_body, "To exit Setup without installing, click Cancel.",      C_BLACK, cx + 8, cy);

    // Button row
    int by = dy + dh - 38;
    separator(r, dx + 4, by - 10, dw - 8);
    draw_button(r, app.f_body, "< Back",  dx + dw - 220, by, 64, 24);
    draw_button(r, app.f_body, "Next >",  dx + dw - 150, by, 64, 24);
    draw_button(r, app.f_body, "Cancel",  dx + dw - 78,  by, 64, 24);

    return next;
}

static bool stage_dest(App& app, bool next) {
    SDL_Renderer* r = app.ren;
    fill(r, C_BG, {0, 0, WIN_W, WIN_H});

    int dx = 80, dy = 50, dw = 480, dh = 380;
    SDL_Rect content = draw_dialog(r, app.f_bold, "Red Alert Setup", dx, dy, dw, dh);
    int cx = content.x, cy = content.y;

    draw_ra_header(r, app.f_bold, app.f_body, cx, cy, content.w);
    cy += 56;

    draw_text(r, app.f_body, "Choose Destination Directory",             C_BLACK, cx + 8, cy); cy += 22;
    draw_text(r, app.f_body, "Setup will install Red Alert in:",         C_BLACK, cx + 8, cy); cy += 20;
    draw_text(r, app.f_body, "To install in this folder, click Next.",   C_BLACK, cx + 8, cy); cy += 32;

    draw_text(r, app.f_body, "Destination Folder:", C_BLACK, cx + 8, cy); cy += 20;

    // Path text box
    int bx = cx + 8, bw = content.w - 100;
    bevel_sunken(r, bx, cy, bw, 22);
    fill(r, C_INPUT_BG, {bx + 2, cy + 2, bw - 4, 18});
    draw_text(r, app.f_small, app.dest.c_str(), C_BLACK, bx + 6, cy + 4);
    draw_button(r, app.f_body, "Browse...", bx + bw + 8, cy, 70, 22);
    cy += 46;

    // Disk space info
    draw_text(r, app.f_small, "Space Required:   80 MB",   C_BLACK, cx + 8, cy); cy += 18;
    draw_text(r, app.f_small, "Space Available:  48.2 GB", C_BLACK, cx + 8, cy);

    int by = dy + dh - 38;
    separator(r, dx + 4, by - 10, dw - 8);
    draw_button(r, app.f_body, "< Back",  dx + dw - 220, by, 64, 24);
    draw_button(r, app.f_body, "Next >",  dx + dw - 150, by, 64, 24);
    draw_button(r, app.f_body, "Cancel",  dx + dw - 78,  by, 64, 24);

    return next;
}

static bool stage_installing(App& app) {
    SDL_Renderer* r = app.ren;
    fill(r, C_BG, {0, 0, WIN_W, WIN_H});

    int dx = 80, dy = 50, dw = 480, dh = 380;
    SDL_Rect content = draw_dialog(r, app.f_bold, "Red Alert Setup", dx, dy, dw, dh);
    int cx = content.x, cy = content.y;

    draw_ra_header(r, app.f_bold, app.f_body, cx, cy, content.w);
    cy += 56;

    draw_text(r, app.f_body, "Installing Red Alert...", C_BLACK, cx + 8, cy); cy += 22;
    draw_text(r, app.f_body, "Please wait while Setup copies files.", C_BLACK, cx + 8, cy); cy += 40;

    // Update progress
    float elapsed_s = (SDL_GetTicks() - app.stage_ts) / 1000.f;
    app.progress = std::min(1.f, elapsed_s / INSTALL_DURATION_S);

    // Current file label
    int fi = std::min((int)(app.progress * INSTALL_FILES.size()),
                      (int)INSTALL_FILES.size() - 1);
    std::string copying = std::string("Copying: ") + INSTALL_FILES[fi];
    draw_text(r, app.f_small, copying.c_str(), C_BLACK, cx + 8, cy); cy += 22;

    // Percentage
    std::string pct = std::to_string((int)(app.progress * 100)) + "% complete";
    draw_text(r, app.f_small, pct.c_str(), C_BLACK, cx + 8, cy); cy += 24;

    draw_progress(r, app.progress, cx + 8, cy, content.w - 16, 20);

    int by = dy + dh - 38;
    separator(r, dx + 4, by - 10, dw - 8);
    draw_button(r, app.f_body, "Cancel", dx + dw - 78, by, 64, 24);

    if (app.progress >= 1.f && !app.installed) {
        do_install(app.dest);
        app.installed = true;
        SDL_Delay(400);
        return true;
    }
    return false;
}

static bool stage_complete(App& app, bool finish) {
    SDL_Renderer* r = app.ren;
    fill(r, C_BG, {0, 0, WIN_W, WIN_H});

    int dx = 80, dy = 50, dw = 480, dh = 380;
    SDL_Rect content = draw_dialog(r, app.f_bold, "Red Alert Setup", dx, dy, dw, dh);
    int cx = content.x, cy = content.y;

    draw_ra_header(r, app.f_bold, app.f_body, cx, cy, content.w);
    cy += 56;

    draw_text(r, app.f_bold,  "Red Alert has been installed!",                    C_BLACK, cx + 8, cy); cy += 28;
    draw_text(r, app.f_body,  "Setup has finished installing Red Alert on your",  C_BLACK, cx + 8, cy); cy += 20;
    draw_text(r, app.f_body,  "computer.",                                         C_BLACK, cx + 8, cy); cy += 36;
    draw_text(r, app.f_body,  "To run Red Alert, use:",                           C_BLACK, cx + 8, cy); cy += 22;

    // Show generated launcher path
    std::string launcher = app.dest + "/run-redalert.sh";
    bevel_sunken(r, cx + 8, cy, content.w - 16, 22);
    fill(r, C_INPUT_BG, {cx + 10, cy + 2, content.w - 20, 18});
    draw_text(r, app.f_small, launcher.c_str(), C_BLACK, cx + 14, cy + 4);
    cy += 44;

    draw_text(r, app.f_body, "Click Finish to exit Setup.", C_BLACK, cx + 8, cy);

    int by = dy + dh - 38;
    separator(r, dx + 4, by - 10, dw - 8);
    draw_button(r, app.f_body, "< Back",  dx + dw - 220, by, 64, 24);
    draw_button(r, app.f_body, "Finish",  dx + dw - 150, by, 64, 24);

    return finish;
}

// ---------- main ----------

int main(int argc, char* argv[]) {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    if (TTF_Init() != 0) {
        fprintf(stderr, "TTF_Init: %s\n", TTF_GetError());
        return 1;
    }
    IMG_Init(IMG_INIT_PNG | IMG_INIT_JPG);

    SDL_Window* win = SDL_CreateWindow("Red Alert Setup",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        WIN_W, WIN_H, SDL_WINDOW_SHOWN);
    if (!win) { fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError()); return 1; }

    SDL_Renderer* ren = SDL_CreateRenderer(win, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!ren) { fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError()); return 1; }

    const char* F_BOLD  = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf";
    const char* F_REG   = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf";

    App app;
    app.ren     = ren;
    app.f_bold  = TTF_OpenFont(F_BOLD, 15);
    app.f_body  = TTF_OpenFont(F_REG,  13);
    app.f_small = TTF_OpenFont(F_REG,  11);

    if (!app.f_bold || !app.f_body || !app.f_small) {
        fprintf(stderr, "TTF_OpenFont: %s\n", TTF_GetError());
        return 1;
    }

    // SETUP.BMP from CD1 PLANETWW directory — splash background
    const char* BMP = "/home/hugh/redalert/CD1/PLANETWW/SETUP.BMP";
    SDL_Surface* bmp_surf = SDL_LoadBMP(BMP);
    if (!bmp_surf) bmp_surf = IMG_Load(BMP);
    if (bmp_surf) {
        app.splash_tex = SDL_CreateTextureFromSurface(ren, bmp_surf);
        app.splash_w   = bmp_surf->w;
        app.splash_h   = bmp_surf->h;
        SDL_FreeSurface(bmp_surf);
    }

    // Destination: argv[1] or ~/redalert
    const char* home = getenv("HOME");
    app.dest = home ? (std::string(home) + "/redalert/CnC_Red_Alert") : "/opt/redalert";
    if (argc > 1) app.dest = argv[1];

    app.stage_ts = SDL_GetTicks();

    bool running = true;
    SDL_Event ev;

    while (running) {
        bool any_input = false;
        bool next = false;
        bool finish = false;

        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT)                             { running = false; }
            if (ev.type == SDL_KEYDOWN) {
                if (ev.key.keysym.sym == SDLK_ESCAPE)           { running = false; }
                if (ev.key.keysym.sym == SDLK_RETURN ||
                    ev.key.keysym.sym == SDLK_SPACE)            { any_input = next = finish = true; }
            }
            if (ev.type == SDL_MOUSEBUTTONUP) {
                any_input = true;
                // Hit-test "Next >" button area
                // Dialog: dx=80, dy=50, dw=480, dh=380 → button row y = dy+dh-38 = 392
                // Next: x = 80+480-150 = 410, w=64
                // Finish: same x
                int bx = ev.button.x, by_e = ev.button.y;
                int btn_y = 392, btn_h = 24;
                if (by_e >= btn_y && by_e <= btn_y + btn_h) {
                    if (bx >= 410 && bx <= 474) { next = true; finish = true; }
                }
                // Splash — click anywhere advances
                if (app.stage == Stage::SPLASH) next = true;
            }
        }

        SDL_SetRenderDrawColor(ren, 192, 192, 192, 255);
        SDL_RenderClear(ren);

        bool advance = false;
        switch (app.stage) {
            case Stage::SPLASH:     advance = stage_splash(app, any_input);    break;
            case Stage::WELCOME:    advance = stage_welcome(app, next);        break;
            case Stage::DEST_DIR:   advance = stage_dest(app, next);           break;
            case Stage::INSTALLING: advance = stage_installing(app);           break;
            case Stage::COMPLETE:   advance = stage_complete(app, finish);     break;
        }

        if (advance) {
            if (app.stage == Stage::COMPLETE) {
                running = false;
            } else {
                app.stage = static_cast<Stage>(static_cast<int>(app.stage) + 1);
                app.stage_ts = SDL_GetTicks();
            }
        }

        SDL_RenderPresent(ren);
        SDL_Delay(16);
    }

    if (app.splash_tex) SDL_DestroyTexture(app.splash_tex);
    TTF_CloseFont(app.f_small);
    TTF_CloseFont(app.f_body);
    TTF_CloseFont(app.f_bold);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    TTF_Quit();
    IMG_Quit();
    SDL_Quit();
    return 0;
}

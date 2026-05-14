#!/usr/bin/env bash
set -u
RUN_DIR="/home/hugh/.paperclip/instances/default/projects/383ed49e-8193-4717-814c-434585b89ce8/65c59b6b-89a8-4b57-8f47-4693ee406ec8/_default/build/run-172"
ELF="/home/hugh/.paperclip/instances/default/projects/383ed49e-8193-4717-814c-434585b89ce8/65c59b6b-89a8-4b57-8f47-4693ee406ec8/_default/build/first-run-pass-72/redalert.elf"
LOG="/tmp/d72h.log"

pkill -f "Xvfb :98" 2>/dev/null || true
Xvfb :98 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

cd "$RUN_DIR" && DISPLAY=:98 SDL_AUDIODRIVER=dummy \
    timeout 30 "$ELF" > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true
echo "Run rc=$RUN_RC" >> "$LOG"

# Without RA_AUTOSTART the game plays intro movies then shows main menu.
# A 30s run covers the boot sequence; check for clean init and no crash.
echo "--- Boot / SDL init ---"
grep -a "SDL\|Init\|redalert\|[Ee]rror" "$LOG" | head -10
echo "--- Movie playback ---"
grep -a "Play_Movie\|VQA\|ENGLISH\|PROLOG" "$LOG" | head -10
echo "--- Crash signals ---"
grep -a "SIGSEGV\|SIGILL\|Segmentation\|abort" "$LOG" | head -5

/**
 * wasm/preloader.js — Game-data preloader for C&C WASM builds (RA + TD).
 *
 * Handles both Red Alert (ra.html) and Tiberian Dawn (td.html).
 * Game is auto-detected from window.location.pathname:
 *   /td.html  → Tiberian Dawn (CONQUER.MIX, GENERAL.MIX, TEMPERAT.MIX, …)
 *   anything  → Red Alert     (REDALERT.MIX, LORES.MIX, HIRES.MIX, …)
 *
 * Two load modes, selected automatically:
 *
 *   ?src=<url>  — S3 / HTTP mode: fetch MIX files from <url>/<FILENAME>.
 *                 The server / bucket must send permissive CORS headers, e.g.:
 *                   AllowedOrigins: ["*"]
 *                   AllowedMethods: ["GET", "HEAD"]
 *                   AllowedHeaders: ["*"]
 *                 No folder-picker dialog is shown; fetches begin immediately.
 *
 *   (no ?src=)  — Local mode: prompt user with showDirectoryPicker() (File
 *                 System Access API).  Chrome/Edge stable only; Firefox needs
 *                 dom.fs.enabled; Safari not supported.
 *
 * URL params:
 *   ?src=<url>     — base URL for MIX file fetch
 *   ?autostart=1   — skip menu, jump straight to first mission (e2e tests)
 *                    RA → sets RA_AUTOSTART env; TD → sets TD_AUTOSTART env
 *
 * Expected DOM element IDs (defined in the embedding HTML shell):
 *   #preloader-overlay  — wrapper hidden after files are ready
 *   #open-btn           — button that triggers showDirectoryPicker() (local mode)
 *   #progress-bar-wrap  — container shown while MIX files are loading
 *   #progress-bar       — inner bar whose width% reflects load progress
 *   #progress-text      — inline text showing "N / M"
 *   #status-line        — single-line status message
 *   #browser-error      — error banner shown on unsupported browsers
 *
 * Emscripten runtime methods required (set via -sEXPORTED_RUNTIME_METHODS):
 *   FS, callMain
 */
(function () {
  'use strict';

  var GAME_DIR = '/game';
  var SAVES_DIR = '/saves';

  // Auto-detect game from HTML filename in the URL path.
  // td.html → Tiberian Dawn; anything else → Red Alert.
  var isTD = window.location.pathname.endsWith('/td.html')
          || window.location.pathname === '/td.html'
          || window.location.pathname === 'td.html';

  var RA_MIX_FILES = [
    'REDALERT.MIX',
    'LOCAL.MIX',
    'LORES.MIX',
    'HIRES.MIX',
    'MAIN.MIX',
    'CONQUER.MIX',
    'SCORES.MIX',
    'SPEECH.MIX',
  ];

  // TIM-404: TD asset list — maps to /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/
  // CCLOCAL.MIX is required first (fonts + common resources loaded in Init_Game).
  var TD_MIX_FILES = [
    'CCLOCAL.MIX',
    'CONQUER.MIX',
    'GENERAL.MIX',
    'LOCAL.MIX',
    'TEMPERAT.MIX',
    'SCORES.MIX',
    'SPEECH.MIX',
    'SOUNDS.MIX',
  ];

  var MIX_FILES = isTD ? TD_MIX_FILES : RA_MIX_FILES;

  var wasmReady = false;
  var pendingFiles = null; // Map<string, Uint8Array>, set once files are ready

  // ?autostart=1 URL param — set once during DOMContentLoaded, read in mountAndLaunch.
  var autostart = false;
  // TIM-540: ?gameclk=1 URL param — same pattern; used to create RA_GAME_CLICK.FLAG.
  var gameclk = false;
  // TIM-621: ?mission_test=1 — re-arms win trigger after FPS audit for mission completion test.
  var missiontest = false;
  // TIM-621: ?quicksave_test=1 — auto save/load at frames 500/550 for save-load roundtrip test.
  var quicksavetest = false;
  // TIM-621: ?debug=1 — enable frame-count logging (RA_DEBUG.FLAG) without autostart side-effects.
  var debugframes = false;
  // TIM-697: ?cheat=1 — inject Flag_To_Win() at frame 200 for win-VQA verification.
  // getenv("RA_CHEAT") returns NULL in PROXY_TO_PTHREAD worker; RA_CHEAT.FLAG is the fallback.
  var cheat = false;
  // TIM-812: ?scenario=SCU02EA — override the autostart scenario name.
  // Used to start a specific mission (e.g. Soviet M2, GDI M2) instead of the
  // default M1.  Creates {RA|TD}_AUTOSTART_SCENARIO.FLAG with the scenario name.
  var scenarioName = '';
  // TIM-695: ?vqa=NAME[,NAME...] — fetch extra standalone VQA file(s) from ?src= base URL and
  // drop them into /game/.  Used by the TD WASM VQA regression test (which needs LOGO.VQA from
  // MOVIES.MIX, but loading the full 425MB MIX is too expensive for a CI run).  Each name is
  // suffixed with .VQA if not already.
  var extraVqaList = [];

  // Hook into Emscripten runtime init.  noInitialRun:true in the Module
  // pre-definition means callMain() won't fire automatically; we call it
  // manually once both WASM and files are ready.
  Module.onRuntimeInitialized = function () {
    wasmReady = true;
    // TIM-844: signal CI test harness that WASM JIT is complete
    // (playbook §5 — gate on this, not waitForFunction with short timeout).
    window.__wasmReady = true;
    if (pendingFiles !== null) {
      mountAndLaunch();
    } else {
      setStatus('WASM ready — pick your game folder to start.');
    }
  };

  function setStatus(msg) {
    var el = document.getElementById('status-line');
    if (el) el.textContent = msg;
  }

  function setProgress(loaded, total) {
    var text = document.getElementById('progress-text');
    if (text) text.textContent = loaded + ' / ' + total;
    var bar = document.getElementById('progress-bar');
    if (bar) bar.style.width = (total > 0 ? Math.round(loaded / total * 100) : 0) + '%';
  }

  function showProgressBar() {
    var wrap = document.getElementById('progress-bar-wrap');
    if (wrap) wrap.style.display = 'block';
  }

  // TIM-904: show an error message in the overlay and re-enable the retry button.
  function showPreloaderError(msg) {
    var errEl = document.getElementById('preloader-error');
    if (errEl) {
      errEl.textContent = msg;
      errEl.style.display = 'block';
    }
    var btn = document.getElementById('open-btn');
    if (btn) btn.disabled = false;
    var retryBtn = document.getElementById('retry-btn');
    if (retryBtn) {
      retryBtn.style.display = 'inline-block';
      retryBtn.onclick = function () {
        if (errEl) errEl.style.display = 'none';
        if (retryBtn) retryBtn.style.display = 'none';
        var pwrap = document.getElementById('progress-bar-wrap');
        if (pwrap) pwrap.style.display = 'none';
        setProgress(0, 0);
        openGameFolder();
      };
    }
  }

  function clearPreloaderError() {
    var errEl = document.getElementById('preloader-error');
    if (errEl) errEl.style.display = 'none';
    var retryBtn = document.getElementById('retry-btn');
    if (retryBtn) retryBtn.style.display = 'none';
  }

  // Normalize a base URL: ensure it ends with exactly one slash.
  function normalizeBaseUrl(url) {
    return url.replace(/\/*$/, '/');
  }

  // S3 / HTTP mode: fetch all MIX files from baseUrl.
  async function fetchFromUrl(baseUrl) {
    var base = normalizeBaseUrl(baseUrl);

    // TIM-904: retry button in S3 mode re-fetches.
    var retryBtn = document.getElementById('retry-btn');
    if (retryBtn) {
      retryBtn.style.display = 'inline-block';
      retryBtn.onclick = function () {
        document.getElementById('preloader-error').style.display = 'none';
        retryBtn.style.display = 'none';
        setProgress(0, 0);
        fetchFromUrl(baseUrl);
      };
    }

    // Hide the local-picker UI; S3 mode starts loading immediately.
    var overlay = document.getElementById('preloader-overlay');
    if (overlay) overlay.style.display = 'none';
    var _canvas = document.getElementById('canvas');
    if (_canvas) _canvas.focus();

    setStatus('Fetching game data from ' + base + '…');
    showProgressBar();

    var files = new Map();
    var loaded = 0;
    setProgress(0, MIX_FILES.length);

    for (var i = 0; i < MIX_FILES.length; i++) {
      var name = MIX_FILES[i];
      var url = base + name;
      try {
        var response = await fetch(url);
        if (!response.ok) {
          if (response.status === 404) {
            console.warn('[preloader] ' + name + ' not found at ' + url + ' — skipping');
          } else {
            console.error('[preloader] HTTP ' + response.status + ' fetching ' + name);
          }
        } else {
          var buf = await response.arrayBuffer();
          files.set(name, new Uint8Array(buf));
          console.log('[preloader] fetched ' + name + ' (' + buf.byteLength + ' bytes)');
        }
      } catch (err) {
        // Network error or CORS rejection — log and skip.
        console.error('[preloader] error fetching ' + name + ': ' + err.message);
      }
      loaded++;
      setProgress(loaded, MIX_FILES.length);
    }

    if (files.size === 0) {
      showPreloaderError('No MIX files could be fetched from ' + base +
        '. Check the URL and CORS configuration.');
      return;
    }

    // TIM-695: also fetch extra standalone VQA files when ?vqa=NAME[,NAME...] is set.
    // These are NOT counted against the MIX_FILES progress denominator; they are
    // best-effort (404 is logged but does not block launch).
    for (var v = 0; v < extraVqaList.length; v++) {
      var vname = extraVqaList[v];
      try {
        var vresp = await fetch(base + vname);
        if (!vresp.ok) {
          console.warn('[preloader] extra VQA ' + vname + ' fetch failed: HTTP ' + vresp.status);
          continue;
        }
        var vbuf = await vresp.arrayBuffer();
        files.set(vname, new Uint8Array(vbuf));
        console.log('[preloader] fetched extra ' + vname + ' (' + vbuf.byteLength + ' bytes)');
      } catch (verr) {
        console.warn('[preloader] extra VQA ' + vname + ' fetch error: ' + verr.message);
      }
    }

    setStatus('Fetched ' + files.size + ' file(s) — mounting…');
    pendingFiles = files;

    if (wasmReady) {
      mountAndLaunch();
    } else {
      setStatus('Fetched ' + files.size + '/' + MIX_FILES.length + ' files — waiting for WASM…');
    }
  }

  // Local mode: prompt with File System Access API directory picker.
  async function openGameFolder() {
    var btn = document.getElementById('open-btn');
    if (btn) btn.disabled = true;
    clearPreloaderError();
    setStatus('Waiting for folder picker…');

    var dirHandle;
    try {
      dirHandle = await window.showDirectoryPicker({ mode: 'read' });
    } catch (err) {
      setStatus(err.name === 'AbortError'
        ? 'Cancelled — click Open Game Folder to try again.'
        : 'Picker error: ' + err.message);
      if (btn) btn.disabled = false;
      return;
    }

    setStatus('Reading MIX files…');
    showProgressBar();
    var files = new Map();
    var loaded = 0;
    setProgress(0, MIX_FILES.length);

    for (var i = 0; i < MIX_FILES.length; i++) {
      var name = MIX_FILES[i];
      try {
        var fileHandle = await dirHandle.getFileHandle(name);
        var file = await fileHandle.getFile();
        var buf = await file.arrayBuffer();
        files.set(name, new Uint8Array(buf));
        console.log('[preloader] loaded ' + name + ' (' + buf.byteLength + ' bytes)');
      } catch (err) {
        if (err.name === 'NotFoundError') {
          console.warn('[preloader] ' + name + ' not found — skipping');
        } else {
          console.error('[preloader] error reading ' + name + ': ' + err.message);
        }
      }
      loaded++;
      setProgress(loaded, MIX_FILES.length);
    }

    if (files.size === 0) {
      showPreloaderError('No MIX files found in that folder. Is this the right directory?');
      if (btn) btn.disabled = false;
      return;
    }

    setStatus('Loaded ' + files.size + '/' + MIX_FILES.length + ' files — mounting…');
    var overlay = document.getElementById('preloader-overlay');
    if (overlay) overlay.style.display = 'none';
    var _canvas = document.getElementById('canvas');
    if (_canvas) _canvas.focus();

    pendingFiles = files;

    if (wasmReady) {
      mountAndLaunch();
    } else {
      setStatus('Waiting for WASM to initialize…');
    }
  }

  function mountAndLaunch() {
    // Emscripten 4.x+ exports FS via Module["FS"], not as a global variable.
    var FS = Module.FS;

    // Create /game in Emscripten MEMFS; ignore EEXIST if called more than once.
    try {
      FS.mkdir(GAME_DIR);
    } catch (ignore) {}

    pendingFiles.forEach(function (data, name) {
      FS.createDataFile(GAME_DIR, name, data, /*canRead=*/true, /*canWrite=*/true, /*canOwn=*/false);
      console.log('[preloader] mounted ' + GAME_DIR + '/' + name);
    });

    // TIM-924: validate game data after mount; blocking error overlay if missing.
    Module._validateGameData();

    // Synthesize the required INI config file if not already in the asset bundle.
    // TIM-399: RA STARTUP.CPP gates init on RawFileClass("REDALERT.INI").Is_Available().
    // TIM-404: TD STARTUP.CPP gates init on RawFileClass("CONQUER.INI").Is_Available().
    //
    // TIM-695: TD uses PlayIntro=No so STARTUP.CPP clears Special.IsFromInstall.
    // IsFromInstall=true in TD silently fast-forwards Select_Game to
    // SEL_START_NEW_GAME (INIT.CPP:1068) AND skips Play_Intro entirely
    // (INIT.CPP:598).  Setting PlayIntro=No restores the canonical first-run
    // path: LOGO.VQA → title screen → main menu.  TD_AUTOSTART tests still
    // bypass the menu via the explicit TD_AUTOSTART check (INIT.CPP:992).
    //
    // RA keeps PlayIntro=True because its Init_Game path uses IsFromInstall
    // differently (ENGLISH.VQA / PROLOG.VQA fire from Play_Intro regardless,
    // gated only on RA_AUTOSTART).
    // TIM-695: Use CRLF (\r\n) line endings — WWGetPrivateProfileString
    // (TIBERIANDAWN/PROFILE.CPP:378) requires '\r' to find the end of a value:
    //     altworkptr = strchr(workptr, '\r');
    // With LF-only line endings, altworkptr == NULL and the value parse aborts
    // back to the caller's default — PlayIntro silently falls back to "Yes",
    // setting Special.IsFromInstall = true and bypassing Play_Intro entirely.
    if (isTD) {
      if (!pendingFiles.has('CONQUER.INI')) {
        var tdIni = '[Intro]\r\nPlayIntro=No\r\n[Options]\r\n';
        var tdIniBytes = new TextEncoder().encode(tdIni);
        FS.createDataFile(GAME_DIR, 'CONQUER.INI', tdIniBytes, true, true, false);
        console.log('[preloader] synthesized ' + GAME_DIR + '/CONQUER.INI');
      }
    } else {
      // RA's INIClass (REDALERT/INI.CPP) tokenises on '\n' and never inspects
      // '\r', so LF-only line endings are intentional here.  Switching to
      // CRLF would leave a stray '\r' in the parsed value (e.g. "True\r"),
      // and ini.Get_Bool would misparse it.
      if (!pendingFiles.has('REDALERT.INI')) {
        var raIni = '[Intro]\nPlayIntro=True\n[Options]\n';
        var raIniBytes = new TextEncoder().encode(raIni);
        FS.createDataFile(GAME_DIR, 'REDALERT.INI', raIniBytes, true, true, false);
        console.log('[preloader] synthesized ' + GAME_DIR + '/REDALERT.INI');
      }
    }

    // TIM-396: Mount IDBFS at /saves for persistent save game storage.
    // TIM-399: Guard gracefully — IDBFS requires -sFORCE_FILESYSTEM=1 at build time.
    var idbfsMounted = false;
    if (FS.filesystems && FS.filesystems.IDBFS) {
      try { FS.mkdir(SAVES_DIR); } catch (ignore) {}
      try {
        FS.mount(FS.filesystems.IDBFS, {}, SAVES_DIR);
        idbfsMounted = true;
        console.log('[idbfs] mounted ' + SAVES_DIR);
      } catch (e) {
        console.warn('[idbfs] mount failed (saves will not persist):', e.message);
      }
    } else {
      console.warn('[idbfs] IDBFS not available in this build — saves will not persist');
    }

    FS.chdir(GAME_DIR);
    console.log('[preloader] cwd → ' + GAME_DIR);

    // TIM-404: ?autostart=1 creates a flag file in MEMFS instead of using Module.ENV.
    // getenv() crashes under PROXY_TO_PTHREAD (C environ not propagated to worker thread).
    // A flag file read via RawFileClass works because MEMFS is shared across all threads.
    if (autostart) {
      var flagFile = isTD ? 'TD_AUTOSTART.FLAG' : 'RA_AUTOSTART.FLAG';
      try {
        FS.createDataFile(GAME_DIR, flagFile, new Uint8Array([1]), true, true, false);
        console.log('[preloader] autostart flag → ' + GAME_DIR + '/' + flagFile);
      } catch (e) {
        console.warn('[preloader] could not create autostart flag file:', e.message);
      }
    }

    // TIM-812: ?scenario=SCU02EA — override the autostart mission.
    if (scenarioName) {
      var scenarioFlagFile = isTD ? 'TD_AUTOSTART_SCENARIO.FLAG' : 'RA_AUTOSTART_SCENARIO.FLAG';
      try {
        var scenarioBytes = new TextEncoder().encode(scenarioName);
        FS.createDataFile(GAME_DIR, scenarioFlagFile, scenarioBytes, true, true, false);
        console.log('[preloader] autostart scenario flag → ' + GAME_DIR + '/' + scenarioFlagFile + ' = ' + scenarioName);
      } catch (e) {
        console.warn('[preloader] could not create scenario flag file:', e.message);
      }
    }

    // TIM-540: ?gameclk=1 creates RA_GAME_CLICK.FLAG in MEMFS for the same reason.
    // getenv("RA_GAME_CLICK") / getenv("TD_GAME_CLICK") returns NULL in the
    // PROXY_TO_PTHREAD worker; the flag file is the C++ fallback.
    // TIM-546: also creates TD_GAME_CLICK.FLAG for the TD build.
    if (gameclk) {
      var clickFlagFile = isTD ? 'TD_GAME_CLICK.FLAG' : 'RA_GAME_CLICK.FLAG';
      try {
        FS.createDataFile(GAME_DIR, clickFlagFile, new Uint8Array([1]), true, true, false);
        console.log('[preloader] gameclk flag → ' + GAME_DIR + '/' + clickFlagFile);
      } catch (e) {
        console.warn('[preloader] could not create gameclk flag file:', e.message);
      }
    }

    // TIM-621: ?mission_test=1 — allow Do_Win() through for mission completion audit.
    if (missiontest) {
      try {
        FS.createDataFile(GAME_DIR, 'RA_MISSION_TEST.FLAG', new Uint8Array([1]), true, true, false);
        console.log('[preloader] mission_test flag → ' + GAME_DIR + '/RA_MISSION_TEST.FLAG');
      } catch (e) {
        console.warn('[preloader] could not create mission_test flag file:', e.message);
      }
    }

    // TIM-621: ?quicksave_test=1 — auto save/load at frames 500/550.
    if (quicksavetest) {
      try {
        FS.createDataFile(GAME_DIR, 'RA_QUICKSAVE_TEST.FLAG', new Uint8Array([1]), true, true, false);
        console.log('[preloader] quicksave_test flag → ' + GAME_DIR + '/RA_QUICKSAVE_TEST.FLAG');
      } catch (e) {
        console.warn('[preloader] could not create quicksave_test flag file:', e.message);
      }
    }

    // TIM-621: ?debug=1 — enable frame-progress logging without enabling autostart game behavior.
    if (debugframes) {
      try {
        FS.createDataFile(GAME_DIR, 'RA_DEBUG.FLAG', new Uint8Array([1]), true, true, false);
        console.log('[preloader] debug flag → ' + GAME_DIR + '/RA_DEBUG.FLAG');
      } catch (e) {
        console.warn('[preloader] could not create debug flag file:', e.message);
      }
    }

    // TIM-697: ?cheat=1 — creates RA_CHEAT.FLAG so C++ _ra_cheat check fires on PROXY_TO_PTHREAD.
    // TIM-774: also creates TD_CHEAT.FLAG for TD build (same pattern; getenv() fails in worker).
    if (cheat) {
      var cheatFlagFile = isTD ? 'TD_CHEAT.FLAG' : 'RA_CHEAT.FLAG';
      try {
        FS.createDataFile(GAME_DIR, cheatFlagFile, new Uint8Array([1]), true, true, false);
        console.log('[preloader] cheat flag → ' + GAME_DIR + '/' + cheatFlagFile);
      } catch (e) {
        console.warn('[preloader] could not create cheat flag file:', e.message);
      }
    }

    function launchGame() {
      setStatus('Starting game…');
      Module.callMain([]);
      if (idbfsMounted) {
        setInterval(function () {
          FS.syncfs(/*populate=*/false, function (syncErr) {
            if (syncErr) console.error('[idbfs] periodic sync error:', syncErr);
          });
        }, 5000);
        window.addEventListener('beforeunload', function () {
          FS.syncfs(false, function () {});
        });
      }
    }

    if (idbfsMounted) {
      setStatus('Restoring saved games…');
      FS.syncfs(/*populate=*/true, function (err) {
        if (err) {
          console.error('[idbfs] startup sync error:', err);
        } else {
          console.log('[idbfs] saves restored from IndexedDB');
        }
        launchGame();
      });
    } else {
      launchGame();
    }
  }

  // TIM-924: C++-callable IDBFS force-sync for save persistence.
  // Called from C++ via EM_ASM({ Module._saveToIDBFS(); }) after Save_Game
  // writes a file to /saves/, ensuring it reaches IndexedDB before the page
  // context can terminate.
  Module._saveToIDBFS = function (callback) {
    var FS = Module.FS;
    if (!FS.filesystems || !FS.filesystems.IDBFS) {
      if (callback) callback('IDBFS not available');
      return;
    }
    FS.syncfs(/*populate=*/false, function (err) {
      if (err) {
        console.error('[idbfs] _saveToIDBFS sync error:', err.message);
        if (callback) callback(err.message);
      } else {
        console.log('[idbfs] _saveToIDBFS sync OK');
        if (callback) callback(null);
      }
    });
  };

  // TIM-924: C++-callable IDBFS force-populate for load.
  // Called from C++ via EM_ASM({ Module._loadFromIDBFS(); }) before Load_Game
  // reads a file from /saves/, ensuring IndexedDB state is synced to MEMFS.
  Module._loadFromIDBFS = function (callback) {
    var FS = Module.FS;
    if (!FS.filesystems || !FS.filesystems.IDBFS) {
      if (callback) callback('IDBFS not available');
      return;
    }
    FS.syncfs(/*populate=*/true, function (err) {
      if (err) {
        console.error('[idbfs] _loadFromIDBFS sync error:', err.message);
        if (callback) callback(err.message);
      } else {
        console.log('[idbfs] _loadFromIDBFS sync OK');
        if (callback) callback(null);
      }
    });
  };

  // TIM-924: validate that essential MIX files are present in /game/.
  // Called from C++ or JS after preload completes.  Returns true when all
  // required files exist; false + error overlay otherwise.
  Module._validateGameData = function () {
    var FS = Module.FS;
    var ESSENTIAL_MIXES = ['REDALERT.MIX', 'LOCAL.MIX', 'MAIN.MIX', 'CONQUER.MIX'];
    var missing = [];
    for (var i = 0; i < ESSENTIAL_MIXES.length; i++) {
      try {
        FS.stat('/game/' + ESSENTIAL_MIXES[i]);
      } catch (e) {
        missing.push(ESSENTIAL_MIXES[i]);
      }
    }
    if (missing.length > 0) {
      showPreloaderError(
        'Missing required game files: ' + missing.join(', ') +
        '. The selected folder may not contain valid game data.'
      );
      return false;
    }
    return true;
  };

  document.addEventListener('DOMContentLoaded', function () {
    var params = new URLSearchParams(window.location.search);

    // ?autostart=1 — skip menu, jump to first mission (used in e2e tests).
    if (params.get('autostart') === '1') {
      autostart = true;
    }
    // ?gameclk=1 — enable synthetic unit-click injection (TIM-537/TIM-540).
    if (params.get('gameclk') === '1') {
      gameclk = true;
    }
    // TIM-621: ?mission_test=1 — mission completion test (win trigger after frame 1050).
    if (params.get('mission_test') === '1') {
      missiontest = true;
    }
    // TIM-621: ?quicksave_test=1 — save/load roundtrip test (auto save frame 500, load frame 550).
    if (params.get('quicksave_test') === '1') {
      quicksavetest = true;
    }
    // TIM-621: ?debug=1 — enable frame logging without autostart (RA_DEBUG.FLAG).
    if (params.get('debug') === '1') {
      debugframes = true;
    }
    // TIM-697: ?cheat=1 — Flag_To_Win() at game frame 200 for win-VQA verification.
    if (params.get('cheat') === '1') {
      cheat = true;
    }
    // TIM-812: ?scenario=SCU02EA — override autostart scenario name.
    // Must be used with ?autostart=1.  Example: ?autostart=1&scenario=SCU02EA
    // loads Soviet Mission 2 instead of the default Allied Mission 1.
    var scenParam = params.get('scenario');
    if (scenParam) {
      scenarioName = scenParam.trim().toUpperCase();
    }
    // TIM-695: ?vqa=NAME[,NAME...] — extra standalone VQA files to fetch alongside the MIX
    // bundle.  Only applies in ?src= S3 mode.  Each entry is normalised to upper-case
    // and suffixed with .VQA if missing.
    var vqaParam = params.get('vqa');
    if (vqaParam) {
      extraVqaList = vqaParam.split(',').map(function (s) {
        s = s.trim().toUpperCase();
        if (!s) return null;
        if (!s.endsWith('.VQA')) s += '.VQA';
        return s;
      }).filter(function (s) { return s !== null; });
    }

    // ?src=<url> param: fetch MIX files from S3 / HTTP instead of local picker.
    var srcParam = params.get('src');
    if (srcParam) {
      fetchFromUrl(srcParam);
      return;
    }

    // Local folder-picker mode.
    var btn = document.getElementById('open-btn');
    if (!btn) return;

    if (!window.showDirectoryPicker) {
      var errBanner = document.getElementById('browser-error');
      if (errBanner) errBanner.style.display = 'block';
      setStatus('File System Access API not available — see the banner above.');
      btn.disabled = true;
      return;
    }

    var gameName = isTD ? 'TD' : 'RA';
    btn.addEventListener('click', openGameFolder);
    setStatus('Click "Open Game Folder" to load your ' + gameName + ' data files.');
  });

})();

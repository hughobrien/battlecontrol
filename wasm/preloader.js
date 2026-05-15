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

  // Hook into Emscripten runtime init.  noInitialRun:true in the Module
  // pre-definition means callMain() won't fire automatically; we call it
  // manually once both WASM and files are ready.
  Module.onRuntimeInitialized = function () {
    wasmReady = true;
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

  // Normalize a base URL: ensure it ends with exactly one slash.
  function normalizeBaseUrl(url) {
    return url.replace(/\/*$/, '/');
  }

  // S3 / HTTP mode: fetch all MIX files from baseUrl.
  async function fetchFromUrl(baseUrl) {
    var base = normalizeBaseUrl(baseUrl);

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
      setStatus('No MIX files could be fetched from ' + base +
        '. Check the URL and CORS configuration.');
      return;
    }

    setStatus('Fetched ' + files.size + '/' + MIX_FILES.length + ' files — mounting…');
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
      setStatus('No MIX files found in that folder. Is this the right directory?');
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

    // Synthesize the required INI config file if not already in the asset bundle.
    // TIM-399: RA STARTUP.CPP gates init on RawFileClass("REDALERT.INI").Is_Available().
    // TIM-404: TD STARTUP.CPP gates init on RawFileClass("CONQUER.INI").Is_Available().
    // PlayIntro=True sets Special.IsFromInstall; the Linux path clears it after reading.
    if (isTD) {
      if (!pendingFiles.has('CONQUER.INI')) {
        var tdIni = '[Intro]\nPlayIntro=True\n[Options]\n';
        var tdIniBytes = new TextEncoder().encode(tdIni);
        FS.createDataFile(GAME_DIR, 'CONQUER.INI', tdIniBytes, true, true, false);
        console.log('[preloader] synthesized ' + GAME_DIR + '/CONQUER.INI');
      }
    } else {
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
    if (cheat) {
      try {
        FS.createDataFile(GAME_DIR, 'RA_CHEAT.FLAG', new Uint8Array([1]), true, true, false);
        console.log('[preloader] cheat flag → ' + GAME_DIR + '/RA_CHEAT.FLAG');
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

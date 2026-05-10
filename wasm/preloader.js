/**
 * wasm/preloader.js — File System Access API preloader for Red Alert WASM.
 *
 * Reads game MIX files from the user's local filesystem via the File System
 * Access API and mounts them into Emscripten MEMFS before callMain() fires.
 *
 * Intended use: loaded in wasm/shell.html (or the TIM-379 full HTML shell)
 * after the Module pre-object is defined with noInitialRun:true.
 *
 * Browser support:
 *   Chrome/Edge stable  — full support
 *   Firefox             — behind dom.fs.enabled in about:config
 *   Safari              — not supported
 *
 * Expected DOM element IDs (defined in the embedding HTML shell):
 *   #preloader-overlay  — wrapper hidden after folder is selected
 *   #open-btn           — button that triggers showDirectoryPicker()
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

  var MIX_FILES = [
    'REDALERT.MIX',
    'LOCAL.MIX',
    'LORES.MIX',
    'HIRES.MIX',
    'MAIN.MIX',
    'CONQUER.MIX',
    'SCORES.MIX',
    'SPEECH.MIX',
  ];

  var wasmReady = false;
  var pendingFiles = null; // Map<string, Uint8Array>, set once folder is read

  // Hook into Emscripten runtime init.  noInitialRun:true in the Module
  // pre-definition means callMain() won't fire automatically; we call it
  // manually once both WASM and files are ready.
  Module.onRuntimeInitialized = function () {
    wasmReady = true;
    setStatus('WASM ready — pick your game folder to start.');
    if (pendingFiles !== null) {
      mountAndLaunch();
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
    var wrap = document.getElementById('progress-bar-wrap');
    if (wrap) wrap.style.display = 'block';
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

    pendingFiles = files;

    if (wasmReady) {
      mountAndLaunch();
    } else {
      setStatus('Waiting for WASM to initialize…');
    }
  }

  function mountAndLaunch() {
    // Create /game in Emscripten MEMFS; ignore EEXIST if called more than once.
    try {
      FS.mkdir(GAME_DIR);
    } catch (ignore) {}

    pendingFiles.forEach(function (data, name) {
      FS.createDataFile(GAME_DIR, name, data, /*canRead=*/true, /*canWrite=*/true, /*canOwn=*/false);
      console.log('[preloader] mounted ' + GAME_DIR + '/' + name);
    });

    FS.chdir(GAME_DIR);
    console.log('[preloader] cwd → ' + GAME_DIR + ', calling main()');
    Module.callMain([]);
  }

  document.addEventListener('DOMContentLoaded', function () {
    var btn = document.getElementById('open-btn');
    if (!btn) return;

    if (!window.showDirectoryPicker) {
      var errBanner = document.getElementById('browser-error');
      if (errBanner) errBanner.style.display = 'block';
      setStatus('File System Access API not available — see the banner above.');
      btn.disabled = true;
      return;
    }

    btn.addEventListener('click', openGameFolder);
    setStatus('Click "Open Game Folder" to load your Red Alert data files.');
  });

})();

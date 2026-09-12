/* upkeep web: reads a project from GitHub or a paste, runs the compiled upkeep
 * engine (engine.js, the same Dart code as the CLI), and renders the result.
 * Everything runs in the browser; the only network calls go to GitHub and
 * pub.dev directly. */
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  var state = { mode: 'repo', source: null, result: null, candidates: [] };

  var ANDROID_FILES = [
    'android/gradle/wrapper/gradle-wrapper.properties',
    'android/settings.gradle.kts', 'android/settings.gradle',
    'android/build.gradle.kts', 'android/build.gradle',
    'android/app/build.gradle.kts', 'android/app/build.gradle'
  ];
  var MAX_DART_FILES = 800;
  var SKIP_DIRS = { build: 1, node_modules: 1, Pods: 1, ephemeral: 1 };
  var VERDICT_ORDER = ['discontinued', 'incompatible', 'dead', 'at_risk', 'sdk_blocked', 'stale', 'healthy', 'unknown'];
  var VERDICT_LABEL = {
    discontinued: 'Discontinued', incompatible: 'Incompatible', dead: 'Dead', at_risk: 'At risk',
    sdk_blocked: 'SDK blocked', stale: 'Stale', healthy: 'Healthy', unknown: 'Unknown'
  };
  var VERDICT_COLOR = {
    discontinued: 'var(--violet)', incompatible: 'var(--rose)', dead: 'var(--rose)', at_risk: 'var(--amber)',
    sdk_blocked: 'var(--sky)', stale: 'var(--grey)', healthy: 'var(--green)', unknown: 'var(--ink-4)'
  };

  // ------------------------------------------------------------------ utils
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function toast(msg) {
    var t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast.timer);
    toast.timer = setTimeout(function () { t.classList.remove('show'); }, 2200);
  }
  function copy(text, done) {
    function fallback() {
      var a = document.createElement('textarea');
      a.value = text; a.style.position = 'fixed'; a.style.opacity = '0';
      document.body.appendChild(a); a.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(a);
      toast(ok ? done : 'Copy failed. Select the text and press Ctrl+C.');
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { toast(done); }, fallback);
    } else {
      fallback();
    }
  }
  function store(key, value) {
    try {
      if (value === undefined) return JSON.parse(localStorage.getItem(key) || 'null');
      localStorage.setItem(key, JSON.stringify(value));
    } catch (e) { return null; }
  }
  async function pool(items, size, fn) {
    var out = new Array(items.length), next = 0;
    async function worker() {
      while (next < items.length) {
        var i = next++;
        out[i] = await fn(items[i], i);
      }
    }
    var workers = [];
    for (var k = 0; k < Math.min(size, items.length); k++) workers.push(worker());
    await Promise.all(workers);
    return out;
  }

  // --------------------------------------------------------------- progress
  var steps = [];
  function progressStart(labels) {
    steps = labels;
    var el = $('progress');
    el.innerHTML = labels.map(function (l, i) { return '<li data-i="' + i + '">' + esc(l) + '</li>'; }).join('');
    el.hidden = false;
  }
  function progressAt(i, label) {
    var items = $('progress').querySelectorAll('li');
    items.forEach(function (li, k) {
      li.className = k < i ? 'done' : (k === i ? 'active' : '');
      if (k === i && label) li.textContent = label;
    });
  }
  function progressEnd() { $('progress').hidden = true; }
  function showError(msg) {
    var e = $('error');
    e.innerHTML = msg;
    e.hidden = false;
    progressEnd();
  }

  // ----------------------------------------------------------------- github
  function parseRepo(input, refParam) {
    var s = input.trim().replace(/\.git$/, '').replace(/\/+$/, '')
      .replace(/^(?:https?:\/\/)?(?:www\.)?github\.com\//i, '');
    var m = s.match(/^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(?:\/(?:tree|blob)\/([^/\s]+))?(?:\/(.*))?$/);
    if (!m) return null;
    return {
      owner: m[1],
      repo: m[2],
      ref: m[3] || refParam || null,
      path: (m[4] || '').replace(/^\/+/, '').replace(/\/?pubspec\.yaml$/, '')
    };
  }

  async function gh(url) {
    var res = await fetch(url, { headers: { Accept: 'application/vnd.github+json' } });
    if (res.status === 404) throw new Error('not-found');
    if (res.status === 403 || res.status === 429) throw new Error('rate-limited');
    if (!res.ok) throw new Error('github-' + res.status);
    return res.json();
  }

  function rawUrl(src, path) {
    return 'https://raw.githubusercontent.com/' + src.owner + '/' + src.repo + '/' +
      encodeURIComponent(src.ref).replace(/%2F/g, '/') + '/' + path.split('/').map(encodeURIComponent).join('/');
  }
  function mirrorUrl(src, path) {
    return 'https://cdn.jsdelivr.net/gh/' + src.owner + '/' + src.repo + (src.ref === 'HEAD' ? '' : '@' + src.ref) + '/' +
      path.split('/').map(encodeURIComponent).join('/');
  }

  /// Reads one file. raw.githubusercontent.com first; when GitHub's file
  /// servers are failing, jsDelivr's mirror of the repository, which the
  /// report then mentions because the mirror can trail the latest commit.
  async function raw(src, path) {
    // After GitHub's file servers fail once in a check, go straight to the
    // mirror rather than paying the retries again for every file.
    for (var attempt = 0; attempt < (src.rawDown ? 0 : 2); attempt++) {
      try {
        var res = await fetch(rawUrl(src, path));
        if (res.status === 404) return null;
        if (res.ok) return await res.text();
      } catch (e) { /* retry */ }
      await new Promise(function (r) { setTimeout(r, 250 * (attempt + 1)); });
    }
    src.rawDown = true;
    // The mirror can fail a file's first request while it fetches it from
    // GitHub, and serve it on the next.
    for (var tryMirror = 0; tryMirror < 3; tryMirror++) {
      try {
        var mirrored = await fetch(mirrorUrl(src, path));
        if (mirrored.status === 404) return null;
        if (mirrored.ok) {
          src.mirror = true;
          return await mirrored.text();
        }
      } catch (e) { /* retry */ }
      await new Promise(function (r) { setTimeout(r, 600 * (tryMirror + 1)); });
    }
    throw new Error('Could not read ' + path + ' from GitHub or its mirror. GitHub may be having trouble; try again shortly.');
  }

  /// Lists every file in the repository: GitHub's API first (one call), then
  /// jsDelivr's listing when GitHub's hourly limit is used up.
  async function listFiles(src) {
    try {
      var tree = await gh('https://api.github.com/repos/' + src.owner + '/' + src.repo + '/git/trees/' +
        encodeURIComponent(src.ref) + '?recursive=1');
      return { truncated: tree.truncated, paths: tree.tree.filter(function (n) { return n.type === 'blob'; }).map(function (n) { return n.path; }) };
    } catch (e) {
      if (e.message === 'not-found') throw e;
      var refs = src.ref === 'HEAD' ? ['main', 'master'] : [src.ref];
      for (var i = 0; i < refs.length; i++) {
        try {
          var res = await fetch('https://data.jsdelivr.com/v1/packages/gh/' + src.owner + '/' + src.repo + '@' +
            encodeURIComponent(refs[i]) + '?structure=flat');
          if (!res.ok) continue;
          var data = await res.json();
          if (!data.files) continue;
          src.ref = refs[i];
          src.mirror = true;
          return { truncated: false, paths: data.files.map(function (f) { return f.name.replace(/^\//, ''); }) };
        } catch (err) { /* next */ }
      }
      e.listingFailed = true;
      throw e;
    }
  }

  async function readRepo(src) {
    progressAt(0, 'Opening github.com/' + src.owner + '/' + src.repo);
    // One API call per check: GitHub allows a browser 60 an hour. Everything
    // else is read from raw.githubusercontent.com, which does not count.
    src.ref = src.ref || 'HEAD';
    var listing;
    try {
      listing = await listFiles(src);
    } catch (e) {
      if (e.message === 'not-found') throw e;
      return readRepoWithoutListing(src, e);
    }
    var paths = listing.paths;
    var tree = { truncated: listing.truncated };
    var set = {};
    paths.forEach(function (p) { set[p] = 1; });

    var pubspecs = paths.filter(function (p) { return p === 'pubspec.yaml' || /\/pubspec\.yaml$/.test(p); })
      .map(function (p) { return p === 'pubspec.yaml' ? '' : p.slice(0, -'/pubspec.yaml'.length); })
      .filter(function (d) { return !/(^|\/)\.[^/]/.test(d) || d === src.path; });
    state.candidates = pubspecs.slice(0, 30);

    if (src.path == null || src.path === '') {
      if (set['pubspec.yaml']) {
        src.path = '';
      } else if (pubspecs.length) {
        var ranked = pubspecs.slice().sort(function (a, b) {
          var score = function (d) {
            var pre = d ? d + '/' : '';
            return (set[pre + 'android/app/build.gradle'] || set[pre + 'android/app/build.gradle.kts'] ? -100 : 0) +
              (/example|test|sample/i.test(d) ? 50 : 0) + d.split('/').length;
          };
          return score(a) - score(b);
        });
        src.path = ranked[0];
      } else {
        throw new Error('no-pubspec');
      }
    }
    var dir = src.path ? src.path + '/' : '';
    if (!set[dir + 'pubspec.yaml']) throw new Error('no-pubspec');

    progressAt(1, 'Reading pubspec, lockfile and Gradle files');
    var pubspec = await raw(src, dir + 'pubspec.yaml');
    var lock = set[dir + 'pubspec.lock'] ? await raw(src, dir + 'pubspec.lock') : null;
    var android = {};
    await pool(ANDROID_FILES.filter(function (f) { return set[dir + f]; }), 6, async function (f) {
      var text = await raw(src, dir + f);
      if (text != null) android[f] = text;
    });
    var rootYaml = {};
    var yamlHere = paths.filter(function (p) {
      return p.indexOf(dir) === 0 && p.slice(dir.length).indexOf('/') === -1 && /\.ya?ml$/.test(p) &&
        !/pubspec\.(yaml|lock)$/.test(p);
    });
    await pool(yamlHere, 6, async function (p) {
      var text = await raw(src, p);
      if (text != null) rootYaml[p.slice(dir.length)] = text;
    });

    var dartPaths = paths.filter(function (p) {
      if (p.indexOf(dir) !== 0 || !/\.dart$/.test(p)) return false;
      var parts = p.slice(dir.length).split('/');
      for (var i = 0; i < parts.length - 1; i++) {
        if (parts[i].charAt(0) === '.' || SKIP_DIRS[parts[i]]) return false;
      }
      return true;
    });
    var dartFiles = null;
    src.dartNote = null;
    if (tree.truncated) {
      src.dartNote = 'The repository is too large for GitHub to list in one request, so code was not read.';
    } else if (dartPaths.length > MAX_DART_FILES) {
      src.dartNote = 'The project has ' + dartPaths.length + ' Dart files, more than a browser check reads, so code was not read.';
    } else {
      dartFiles = {};
      var read = 0;
      try {
        await pool(dartPaths, 16, async function (p) {
          var text = await raw(src, p);
          if (text != null) dartFiles[p.slice(dir.length)] = text;
          read++;
          if (read % 20 === 0 || read === dartPaths.length) {
            progressAt(2, 'Reading Dart code (' + read + ' of ' + dartPaths.length + ' files)');
          }
        });
        src.dartCount = dartPaths.length;
      } catch (e) {
        // A partial read would make "nothing imports this" untrustworthy, so
        // the whole index is dropped and the check goes on without it.
        dartFiles = null;
        src.dartNote = 'Some of the code could not be read from GitHub, so upkeep did not use it.';
      }
    }
    if (!dartPaths.length) progressAt(2, 'No Dart code to read');
    return { pubspec: pubspec, lock: lock, android: android, rootYaml: rootYaml, dartFiles: dartFiles };
  }

  /// Without the file listing (rate limited, or GitHub unavailable), the
  /// pubspec, lockfile and Gradle files still live at known paths. Code cannot
  /// be found without a listing, so references stay unknown and nothing is
  /// planned for automatic removal.
  async function readRepoWithoutListing(src, cause) {
    var dir = src.path ? src.path + '/' : '';
    progressAt(1, 'Reading project files directly');
    var pubspec = await raw(src, dir + 'pubspec.yaml');
    if (pubspec == null) throw new Error(cause.message === 'rate-limited' ? 'rate-limited' : 'no-pubspec');
    var lock = await raw(src, dir + 'pubspec.lock');
    var android = {};
    await pool(ANDROID_FILES, 7, async function (f) {
      var text = await raw(src, dir + f);
      if (text != null) android[f] = text;
    });
    progressAt(2, 'Skipping code: GitHub did not list the repository');
    src.dartNote = cause.message === 'rate-limited'
      ? 'GitHub\'s hourly limit for listing repositories was reached, so the code was not read.'
      : 'GitHub did not list the repository, so the code was not read.';
    return { pubspec: pubspec, lock: lock, android: android, rootYaml: {}, dartFiles: null };
  }

  function repoError(err, src) {
    var name = src ? esc(src.owner + '/' + src.repo) : 'that repository';
    switch (err.message) {
      case 'not-found':
        return '<b>' + name + '</b> was not found. It may be private: this page can only read public repositories. ' +
          'For a private project, paste its pubspec, or run <code>upkeep scan</code> locally.';
      case 'rate-limited':
        return 'GitHub limits how often a browser may ask about repositories (60 times an hour). Try again later, ' +
          'or paste the pubspec instead.';
      case 'no-pubspec':
        return 'No <code>pubspec.yaml</code> was found in <b>' + name + '</b>' + (src && src.path ? ' at <code>' + esc(src.path) + '</code>' : '') + '.';
      default:
        return esc(err.message || String(err));
    }
  }

  // ------------------------------------------------------------------- run
  async function run(evt) {
    if (evt) evt.preventDefault();
    $('error').hidden = true;
    var dart = $('dart').value.trim();
    if (!/^\d+\.\d+\.\d+$/.test(dart)) {
      showError('Set the Dart version as three numbers, like <code>3.13.3</code>.');
      return;
    }
    var buttons = document.querySelectorAll('.run');
    buttons.forEach(function (b) { b.disabled = true; });

    var src, input;
    try {
      if (state.mode === 'repo') {
        src = parseRepo($('repo').value, new URLSearchParams(location.search).get('ref'));
        if (!src) {
          showError('Enter a repository as <code>owner/repo</code> or a github.com link.');
          return;
        }
        src.kind = 'repo';
        progressStart(['Opening repository', 'Reading project files', 'Reading Dart code', 'Asking pub.dev about every dependency', 'Judging and planning fixes']);
        try {
          input = await readRepo(src);
        } catch (e) {
          showError(repoError(e, src));
          return;
        }
      } else {
        var pubspecText = $('pubspec').value;
        if (!pubspecText.trim()) {
          showError('Paste the contents of <code>pubspec.yaml</code> first.');
          return;
        }
        src = { kind: 'paste' };
        input = { pubspec: pubspecText, lock: $('lock').value.trim() || null, android: {}, rootYaml: {}, dartFiles: null };
        progressStart(['Reading pubspec', 'Asking pub.dev about every dependency', 'Judging and planning fixes']);
        progressAt(1);
      }

      progressAt(src.kind === 'repo' ? 3 : 1);
      var request = {
        pubspec: input.pubspec, lock: input.lock, android: input.android, rootYaml: input.rootYaml,
        dartFiles: input.dartFiles, dartVersion: dart
      };
      var slowTimer = setTimeout(function () {
        progressAt(src.kind === 'repo' ? 4 : 2);
      }, 1800);
      var result = JSON.parse(await window.upkeepEngine.analyze(JSON.stringify(request)));
      clearTimeout(slowTimer);
      if (!result.ok) {
        showError(esc(result.error));
        return;
      }
      progressEnd();
      state.source = src;
      state.result = result;
      if (src.kind === 'repo') {
        var q = src.owner + '/' + src.repo + (src.path ? '/' + src.path : '');
        history.replaceState(null, '', '?repo=' + encodeURIComponent(q).replace(/%2F/g, '/') +
          (src.ref && src.ref !== 'HEAD' ? '&ref=' + encodeURIComponent(src.ref) : '') + '&dart=' + dart);
      }
      render();
    } finally {
      buttons.forEach(function (b) { b.disabled = false; });
    }
  }

  // ---------------------------------------------------------------- render
  function blobUrl(file, line) {
    var s = state.source;
    if (!s || s.kind !== 'repo') return null;
    return 'https://github.com/' + s.owner + '/' + s.repo + '/blob/' + encodeURIComponent(s.ref) + '/' +
      (s.path ? s.path + '/' : '') + file + (line ? '#L' + line : '');
  }

  function referencesByPackage() {
    var map = {};
    (state.result.fix.todos || []).forEach(function (t) {
      var m = t.title.match(/^(?:Replace|Plan a move off) ([A-Za-z0-9_]+)/);
      if (m && t.references.length) map[m[1]] = t.references;
    });
    return map;
  }

  function render() {
    var r = state.result, scan = r.scan, fix = r.fix, s = state.source;
    document.body.classList.add('has-results');
    $('results').hidden = false;

    $('r-source').textContent = s.kind === 'repo'
      ? 'github.com/' + s.owner + '/' + s.repo + (s.path ? ' / ' + s.path : '')
      : 'Pasted pubspec';
    $('r-name').textContent = scan.project.name;
    var meta = [scan.summary.direct + ' dependencies checked', 'judged against Dart ' + scan.project.dart];
    if (s.kind === 'repo') {
      meta.push(r.referencesRead ? (s.dartCount || 0) + ' Dart files read' : (s.dartNote || 'code not read'));
      if (s.mirror) meta.push('some files read from jsDelivr\'s mirror, which can trail the latest commit by a few hours');
    }
    $('r-meta').textContent = meta.join('  ·  ');

    renderSummary(scan);
    renderDeps(scan);
    renderAndroid(scan);
    renderFix(fix, r.referencesRead);
    renderCi();
    selectTab($('t-deps'));
    $('results').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'start' });
  }

  function renderSummary(scan) {
    var deps = scan.dependencies, sum = scan.summary;
    var healthy = deps.filter(function (d) { return d.verdict === 'healthy' || d.verdict === 'stale' || d.verdict === 'sdk_blocked'; }).length;
    var pct = deps.length ? Math.round(healthy / deps.length * 100) : 100;
    var failing = sum.blocking + sum.buildFailures;
    var cls = failing ? 'state-bad' : (sum.atRisk ? 'state-warn' : 'state-ok');
    var title = failing ? 'Needs work' : (sum.atRisk ? 'Healthy, with warnings' : 'Clean');
    var line = failing
      ? 'Exit code 1: this would fail a CI build.'
      : (sum.atRisk ? 'Nothing blocks a build. Some packages are worth planning around.' : 'Nothing blocks a build. Exit code 0.');
    var color = failing ? 'var(--rose)' : (sum.atRisk ? 'var(--amber)' : 'var(--green)');
    var c = 2 * Math.PI * 36;
    var android = scan.android.checked
      ? (sum.buildFailures ? { v: sum.buildFailures, s: sum.buildFailures === 1 ? 'combination that does not build' : 'combinations that do not build', k: 'bad' }
        : { v: 'OK', s: 'Gradle, AGP and SDK line up', k: 'ok' })
      : { v: '—', s: 'no android/ folder', k: '' };

    $('summary').innerHTML =
      '<div class="card verdict-card ' + cls + '">' +
        '<div class="ring"><svg viewBox="0 0 84 84" aria-hidden="true">' +
          '<circle cx="42" cy="42" r="36" fill="none" stroke="rgba(255,255,255,.08)" stroke-width="8"/>' +
          '<circle cx="42" cy="42" r="36" fill="none" stroke="' + color + '" stroke-width="8" stroke-linecap="round" ' +
            'stroke-dasharray="' + (c * pct / 100).toFixed(1) + ' ' + c.toFixed(1) + '"/>' +
        '</svg><b>' + pct + '%</b></div>' +
        '<div><h3>' + title + '</h3><p>' + esc(line) + '</p><p>' + healthy + ' of ' + deps.length + ' dependencies without problems.</p></div>' +
      '</div>' +
      stat('Blocking', sum.blocking, 'discontinued, incompatible or dead', sum.blocking ? 'bad' : 'ok') +
      stat('At risk', sum.atRisk, 'still work, worth a plan', sum.atRisk ? 'warn' : 'ok') +
      stat('Android build', android.v, android.s, android.k);

    $('c-deps').textContent = scan.dependencies.length;
    var cf = $('c-android');
    cf.textContent = scan.android.checked ? (sum.buildFailures || '✓') : '—';
    cf.className = sum.buildFailures ? 'alert' : '';
  }

  function stat(k, v, s, cls) {
    return '<div class="card stat ' + (cls || '') + '"><span class="k">' + esc(k) + '</span><span class="v">' + esc(v) +
      '</span><span class="s">' + esc(s) + '</span></div>';
  }

  var activeFilter = 'attention';
  function renderDeps(scan) {
    var deps = scan.dependencies;
    var counts = {};
    deps.forEach(function (d) { counts[d.verdict] = (counts[d.verdict] || 0) + 1; });
    var attention = deps.filter(needsAttention).length;
    activeFilter = attention ? 'attention' : 'all';

    var chips = [['attention', 'Needs attention', attention, 'var(--rose)'], ['all', 'All', deps.length, 'var(--ink-3)']];
    VERDICT_ORDER.forEach(function (v) { if (counts[v]) chips.push([v, VERDICT_LABEL[v], counts[v], VERDICT_COLOR[v]]); });
    $('filters').innerHTML = chips.map(function (c) {
      return '<button type="button" class="filter" data-filter="' + c[0] + '" aria-pressed="' + (c[0] === activeFilter) + '">' +
        '<i style="background:' + c[3] + '"></i>' + esc(c[1]) + ' <span>' + c[2] + '</span></button>';
    }).join('');
    $('filters').querySelectorAll('.filter').forEach(function (b) {
      b.addEventListener('click', function () {
        activeFilter = b.getAttribute('data-filter');
        $('filters').querySelectorAll('.filter').forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
        drawDeps();
      });
    });
    drawDeps();
  }

  function needsAttention(d) {
    return ['discontinued', 'incompatible', 'dead', 'at_risk', 'unknown'].indexOf(d.verdict) !== -1;
  }

  function drawDeps() {
    var refs = referencesByPackage();
    var deps = state.result.scan.dependencies.filter(function (d) {
      return activeFilter === 'all' || (activeFilter === 'attention' ? needsAttention(d) : d.verdict === activeFilter);
    });
    if (!deps.length) {
      $('deps').innerHTML = '<div class="empty">Nothing here. Every dependency in this view checks out.</div>';
      return;
    }
    $('deps').innerHTML = deps.map(function (d, i) {
      var sub = d.reasons.length ? d.reasons[0] : 'No warning signs';
      var ver = d.resolved
        ? esc(d.resolved) + (d.behind ? ' <span class="up">→ ' + esc(d.latest) + '</span>' : '')
        : (d.latest ? 'latest ' + esc(d.latest) : '');
      var body = '<ul class="reasons">' + (d.reasons.length ? d.reasons : ['No warning signs.']).map(function (x) {
        return '<li>' + esc(x) + '</li>';
      }).join('') + '</ul>';
      if (d.replacement) {
        var by = d.replacement.source === 'curated'
          ? 'named at <a href="' + esc(d.replacement.evidence) + '" target="_blank" rel="noopener">its source</a>'
          : 'named by its publisher';
        body += '<div class="successor">Move to <b>' + esc(d.replacement.package) + '</b> <span>' + by + '</span>' +
          ' <a href="https://pub.dev/packages/' + esc(d.replacement.package) + '" target="_blank" rel="noopener">pub.dev ↗</a></div>';
      }
      var r = refs[d.name];
      if (r) {
        body += '<div class="refs">' + r.slice(0, 12).map(function (ref) {
          var url = blobUrl(ref.file, ref.line);
          var label = esc(ref.file + ':' + ref.line);
          return url ? '<a href="' + esc(url) + '" target="_blank" rel="noopener">' + label + '</a>' : '<a>' + label + '</a>';
        }).join('') + (r.length > 12 ? '<span class="pill-note">and ' + (r.length - 12) + ' more</span>' : '') + '</div>';
      }
      body += '<div class="facts"><span>declared ' + esc(d.declared || 'any') + '</span>' +
        (d.dev ? '<span>dev dependency</span>' : '') +
        '<a href="https://pub.dev/packages/' + esc(d.name) + '" target="_blank" rel="noopener">pub.dev/packages/' + esc(d.name) + ' ↗</a></div>';

      return '<div class="dep" data-i="' + i + '">' +
        '<button type="button" class="dep-row" aria-expanded="false">' +
          '<span class="badge v-' + d.verdict + '">' + esc(d.label) + '</span>' +
          '<span><span class="dep-name">' + esc(d.name) + (d.dev ? '<small>dev</small>' : '') + '</span>' +
            '<span class="dep-sub">' + esc(sub) + '</span></span>' +
          '<span class="ver">' + ver + '</span>' +
          '<svg class="chev" aria-hidden="true"><use href="#i-down"/></svg>' +
        '</button>' +
        '<div class="dep-body" hidden>' + body + '</div>' +
      '</div>';
    }).join('');
    $('deps').querySelectorAll('.dep-row').forEach(function (row) {
      row.addEventListener('click', function () {
        var dep = row.parentNode, open = !dep.classList.contains('open');
        dep.classList.toggle('open', open);
        row.setAttribute('aria-expanded', String(open));
        dep.querySelector('.dep-body').hidden = !open;
      });
    });
    var first = $('deps').querySelector('.dep-row');
    if (first && activeFilter === 'attention') first.click();
  }

  function cmdBlock(text) {
    return '<div class="cmd"><code>' + esc(text) + '</code><button type="button" class="icon-btn" data-copy="' + esc(text) +
      '" aria-label="Copy command"><svg aria-hidden="true"><use href="#i-copy"/></svg></button></div>';
  }

  function renderAndroid(scan) {
    var p = $('p-android');
    if (!scan.android.checked) {
      p.innerHTML = '<div class="empty">No <code>android/</code> folder, so there is no build matrix to check.</div>';
      return;
    }
    p.innerHTML = '<div class="findings">' + scan.android.findings.map(function (f) {
      var fixCmd = f.fix ? cmdBlock(f.fix) + (f.fixWhere ? '<p style="margin-top:.35rem">' + esc(f.fixWhere) + '</p>' : '') : '';
      return '<div class="card finding"><span class="lvl lvl-' + f.level + '">' + (f.level === 'unchecked' ? 'SKIPPED' : f.level.toUpperCase()) + '</span>' +
        '<div><h4>' + esc(f.title) + '</h4>' + (f.detail ? '<p>' + esc(f.detail) + '</p>' : '') + fixCmd + '</div></div>';
    }).join('') + '</div>';
  }

  function sourceKey() {
    var s = state.source;
    return 'upkeep:todos:' + (s.kind === 'repo' ? s.owner + '/' + s.repo + '/' + (s.path || '') : state.result.scan.project.name);
  }

  function renderFix(fix, referencesRead) {
    var auto = fix.automatic, todos = fix.todos;
    var n = auto.length + todos.filter(function (t) { return t.blocking; }).length;
    var badge = $('c-fix');
    badge.textContent = auto.length + todos.length;
    badge.className = n ? 'alert' : '';
    var done = store(sourceKey()) || {};

    var autoHtml = auto.length ? auto.map(function (a, i) {
      return '<div class="item"><div class="item-title"><span class="n">' + (i + 1) + '</span><span>' + esc(a.title) + '</span></div>' +
        '<span class="file">' + esc(a.file) + '</span><ul>' + a.reasons.map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('') + '</ul></div>';
    }).join('') + '<div class="apply-box"><p>Make these changes, verified by <code>pub get</code> and reversible with git:</p>' +
      cmdBlock('upkeep fix --apply') + '<p style="margin-top:.7rem">Or let the GitHub Action open the pull request for you, from the <b>Keep it healthy</b> tab.</p></div>'
      : '<p class="lead-note">' + (referencesRead
        ? 'Nothing here can be changed safely without a person.'
        : 'This check did not read the project\'s code, so upkeep removes nothing automatically. Check a GitHub repository, or run <code>upkeep fix</code> locally, to see what it can change for you.') + '</p>';

    var todoHtml = todos.length ? todos.map(function (t, i) {
      var id = t.title;
      var refs = t.references.length ? '<div class="refs">' + t.references.slice(0, 10).map(function (ref) {
        var url = blobUrl(ref.file, ref.line);
        var label = esc(ref.file + ':' + ref.line);
        return url ? '<a href="' + esc(url) + '" target="_blank" rel="noopener">' + label + '</a>' : '<a>' + label + '</a>';
      }).join('') + '</div>' : '';
      return '<div class="item' + (done[id] ? ' done' : '') + '"><label class="item-title"><input type="checkbox" data-todo="' + esc(id) + '"' + (done[id] ? ' checked' : '') + '>' +
        '<span>' + esc(t.title) + '</span>' + (t.blocking ? '' : '<span class="pill-note">not blocking</span>') + '</label>' +
        '<ul>' + t.reasons.map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('') + (t.action ? '<li>' + esc(t.action) + '</li>' : '') + '</ul>' + refs + '</div>';
    }).join('') : '<p class="lead-note">No to-dos. Nothing needs a person.</p>';

    $('p-fix').innerHTML = '<div class="plan">' +
      '<div class="card"><h3><i></i>Automatic <b class="pill-note">' + auto.length + '</b></h3><p class="lead-note">Changes upkeep makes on its own. Each follows from published data and touches one file.</p>' + autoHtml + '</div>' +
      '<div class="card todo-col"><h3><i></i>To do <b class="pill-note">' + todos.length + '</b></h3><p class="lead-note">Needs judgement. Tick items off as you go; this browser remembers.</p>' + todoHtml + '</div>' +
    '</div>';

    $('p-fix').querySelectorAll('input[data-todo]').forEach(function (box) {
      box.addEventListener('change', function () {
        var all = store(sourceKey()) || {};
        all[box.getAttribute('data-todo')] = box.checked;
        store(sourceKey(), all);
        box.closest('.item').classList.toggle('done', box.checked);
      });
    });
  }

  function renderCi() {
    var path = state.source.kind === 'repo' && state.source.path ? state.source.path : '';
    var withPath = path ? '\n        with:\n          path: ' + path : '';
    var scanYaml = 'name: upkeep\non:\n  pull_request:\n  schedule:\n    - cron: "0 6 * * 1"\n\njobs:\n  scan:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: Minas-27/upkeep@main' + withPath;
    var fixYaml = 'name: upkeep fixes\non:\n  schedule:\n    - cron: "0 6 * * 1"\n\njobs:\n  fix:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: write\n      pull-requests: write\n    steps:\n      - uses: actions/checkout@v4\n      - uses: Minas-27/upkeep@main\n        with:\n          command: fix-pr' + (path ? '\n          path: ' + path : '');
    function code(text) {
      return '<div class="code"><pre>' + esc(text) + '</pre><button type="button" class="icon-btn" data-copy="' + esc(text) + '" aria-label="Copy"><svg aria-hidden="true"><use href="#i-copy"/></svg></button></div>';
    }
    $('p-ci').innerHTML = '<div class="ci-grid">' +
      '<div class="card"><h3>Check every pull request</h3><p>Fails the build on blocking findings and writes this report into the job summary.</p>' + code(scanYaml) + '</div>' +
      '<div class="card"><h3>Get the fixes as a pull request</h3><p>Every Monday, applies the safe fixes, verifies them, and opens one pull request with the rest as a checklist. Allow Actions to open pull requests under Settings → Actions → General.</p>' + code(fixYaml) + '</div>' +
      '<div class="card"><h3>In your terminal</h3><p>The same engine, with your real JDK and <code>fix --apply</code>.</p>' + cmdBlock('dart pub global activate upkeep') + cmdBlock('upkeep scan') + '</div>' +
      '<div class="card"><h3>Share this report</h3><p>A link that re-runs this check for anyone, or the full report as Markdown for an issue or pull request.</p>' +
        '<div class="head-actions"><button class="btn sm" type="button" data-action="share"><svg aria-hidden="true"><use href="#i-link"/></svg>Copy link</button>' +
        '<button class="btn sm" type="button" data-action="markdown"><svg aria-hidden="true"><use href="#i-copy"/></svg>Copy Markdown</button></div></div>' +
    '</div>';
  }

  // ------------------------------------------------------------------ tabs
  function selectTab(tab, focus) {
    document.querySelectorAll('.tabs .tab').forEach(function (t) {
      var on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      $(t.getAttribute('aria-controls')).hidden = !on;
    });
    if (focus) tab.focus();
  }
  function wireTabs(selector, onSelect) {
    var tabs = Array.prototype.slice.call(document.querySelectorAll(selector));
    tabs.forEach(function (t, i) {
      t.addEventListener('click', function () { onSelect(t); });
      t.addEventListener('keydown', function (e) {
        var next = null;
        if (e.key === 'ArrowRight') next = tabs[(i + 1) % tabs.length];
        if (e.key === 'ArrowLeft') next = tabs[(i - 1 + tabs.length) % tabs.length];
        if (next) { e.preventDefault(); onSelect(next, true); }
      });
    });
  }

  function setMode(tab, focus) {
    document.querySelectorAll('.mode').forEach(function (m) {
      var on = m === tab;
      m.setAttribute('aria-selected', String(on));
      m.tabIndex = on ? 0 : -1;
      $(m.getAttribute('aria-controls')).hidden = !on;
    });
    state.mode = tab.id === 'mode-paste' ? 'paste' : 'repo';
    if (focus) tab.focus();
  }

  // ------------------------------------------------------------------ init
  function shareLink() {
    if (!state.source || state.source.kind !== 'repo') {
      toast('Links work for GitHub repositories. Copy the report instead.');
      return;
    }
    copy(location.href, 'Link copied');
  }
  function copyMarkdown() {
    if (!state.result) return;
    copy(state.result.markdown.scan + '\n' + state.result.markdown.fix, 'Report copied as Markdown');
  }

  async function latestDart() {
    try {
      var res = await fetch('https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION');
      var v = (await res.json()).version;
      if (/^\d+\.\d+\.\d+$/.test(v)) return v;
    } catch (e) { /* fall through */ }
    return '3.13.3';
  }

  async function init() {
    if (!window.upkeepEngine) {
      showError('The upkeep engine did not load. Refresh the page.');
      return;
    }
    $('engine-version').textContent = window.upkeepEngine.version;
    wireTabs('.tabs .tab', selectTab);
    wireTabs('.mode', setMode);
    document.querySelectorAll('.mode').forEach(function (m) { m.addEventListener('click', function () { setMode(m); }); });
    $('form').addEventListener('submit', run);
    document.querySelectorAll('[data-example]').forEach(function (b) {
      b.addEventListener('click', function () {
        setMode($('mode-repo'));
        $('repo').value = b.getAttribute('data-example');
        run();
      });
    });
    $('share').addEventListener('click', shareLink);
    $('copy-md').addEventListener('click', copyMarkdown);
    document.addEventListener('click', function (e) {
      var c = e.target.closest('[data-copy]');
      if (c) copy(c.getAttribute('data-copy'), 'Copied');
      var a = e.target.closest('[data-action]');
      if (a && a.getAttribute('data-action') === 'share') shareLink();
      if (a && a.getAttribute('data-action') === 'markdown') copyMarkdown();
    });

    var params = new URLSearchParams(location.search);
    $('dart').value = /^\d+\.\d+\.\d+$/.test(params.get('dart') || '') ? params.get('dart') : await latestDart();
    if (params.get('repo')) {
      $('repo').value = params.get('repo');
      run();
    } else {
      $('repo').focus();
    }
  }

  init();
})();

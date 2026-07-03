/* Cachesweep landing  behavior.
 * Everything degrades: no GSAP → static page; reduced motion → no loops. */
(function () {
  'use strict';

  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* automated agents (headless screenshots, crawlers) get the finished,
   * canonical page  no entrance choreography, no demo cycle */
  var scripted = navigator.webdriver === true || /[?&#]static/.test(location.href);

  /* ---------------------------------------------------------- utilities -- */

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  /* macOS ByteCountFormatter-ish: decimal units, "Zero KB" for nothing */
  function fmtBytes(b) {
    if (b <= 0) return 'Zero KB';
    var GB = 1e9, MB = 1e6, KB = 1e3;
    var s;
    if (b >= GB) s = trimZeros((b / GB).toFixed(2)) + ' GB';
    else if (b >= MB) s = trimZeros((b / MB).toFixed(1)) + ' MB';
    else if (b >= KB) s = Math.round(b / KB) + ' KB';
    else s = Math.round(b) + ' bytes';
    return s;
  }
  function trimZeros(s) { return s.replace(/\.?0+$/, ''); }

  /* tiny tween so the demo runs even if the GSAP CDN is blocked */
  function tween(from, to, ms, onUpdate, onDone) {
    if (reduced) { onUpdate(to); if (onDone) onDone(); return; }
    var t0 = performance.now();
    (function step(now) {
      var t = Math.max(0, Math.min(1, (now - t0) / ms));
      var e = 1 - Math.pow(1 - t, 3); /* easeOutCubic */
      onUpdate(from + (to - from) * e);
      if (t < 1) requestAnimationFrame(step);
      else if (onDone) onDone();
    })(t0);
  }

  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  /* ------------------------------------------------------------- glass -- */

  /* Bake the glass textures BEFORE the entrance plays, so the animation
   * moves finished, cached layers (compositor-only). The popover lens is
   * a one-time filter raster, attached after the entrance settles. */
  var glassReady = window.LiquidGlass ? window.LiquidGlass.build() : Promise.resolve();

  function attachLens() {
    if (window.LiquidGlass) window.LiquidGlass.lens($('#popover'));
  }

  /* ------------------------------------------------------------- clock -- */

  var clock = $('#mbClock');
  function tick() {
    var d = new Date();
    clock.textContent =
      d.toLocaleDateString('en-US', { weekday: 'short' }) + ' ' +
      d.toLocaleDateString('en-US', { month: 'short' }) + ' ' + d.getDate() + '  ' +
      d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  }
  if (clock) { tick(); setInterval(tick, 15000); }

  /* --------------------------------------- popover arrow → menu extra -- */

  var popover = $('#popover'), arrow = $('#popArrow'), sweepItem = $('#mbSweep');
  function aimArrow() {
    if (!popover || !arrow || !sweepItem) return;
    if (window.innerWidth < 1120) return; /* popover is in-flow there */
    var pr = popover.getBoundingClientRect();
    var sr = sweepItem.getBoundingClientRect();
    var right = pr.right - (sr.left + sr.width / 2) - 7;
    arrow.style.right = Math.max(18, Math.min(pr.width - 32, right)) + 'px';
  }
  aimArrow();
  window.addEventListener('resize', aimArrow);

  /* -------------------------------------------------- dock magnification -- */

  var dock = $('#dock');
  if (dock && !reduced && matchMedia('(pointer: fine)').matches) {
    var items = $$('.dock-item', dock);
    var current = items.map(function () { return 1; });
    var target = items.map(function () { return 1; });
    /* real macOS magnification is modest  ~1.3× peak, tight falloff */
    var AMP = 0.3, SIGMA = 62, raf = null;

    /* Geometry is measured ONCE (offsetLeft ignores transforms)  reading
     * getBoundingClientRect() per mousemove forces layout between style
     * writes and janks the whole animation. */
    var dockLeft = 0, centers = [];
    function measure() {
      dockLeft = dock.getBoundingClientRect().left;
      centers = items.map(function (el) { return el.offsetLeft + el.offsetWidth / 2; });
    }
    window.addEventListener('resize', measure);

    function frame() {
      var busy = false;
      for (var i = 0; i < items.length; i++) {
        var next = current[i] + (target[i] - current[i]) * 0.35;
        if (Math.abs(next - current[i]) < 0.0015 && Math.abs(target[i] - next) < 0.0015) {
          next = target[i];
        } else {
          busy = true;
        }
        if (next === current[i]) continue;
        current[i] = next;
        var lift = (next - 1) * 16;
        /* scale + lift only  pushing neighbors would resize the dock and
         * force the glass surface to re-rasterize every frame */
        items[i].style.transform = 'translateY(' + (-lift) + 'px) scale(' + next + ')';
      }
      raf = busy ? requestAnimationFrame(frame) : null;
    }
    function kick() { if (!raf) raf = requestAnimationFrame(frame); }

    dock.addEventListener('mouseenter', measure);
    dock.addEventListener('mousemove', function (e) {
      var x = e.clientX - dockLeft;
      for (var i = 0; i < items.length; i++) {
        var d = x - centers[i];
        target[i] = 1 + AMP * Math.exp(-(d * d) / (2 * SIGMA * SIGMA));
      }
      kick();
    });
    dock.addEventListener('mouseleave', function () {
      for (var i = 0; i < items.length; i++) target[i] = 1;
      kick();
    });
  }

  /* -------------------------------------------------- live activity feed -- */

  function liveRow(sizeEl, deltaEl, whenEl, bytes0, delta0, rate) {
    var state = { bytes: bytes0, delta: delta0, last: Date.now() - Math.random() * 20000 };
    var cap = delta0 + 220e6; /* growth is a loop, not a runaway counter */
    function render() {
      sizeEl.textContent = fmtBytes(state.bytes);
      deltaEl.textContent = '▲ ' + fmtBytes(state.delta);
      var s = Math.round((Date.now() - state.last) / 1000);
      whenEl.textContent = '· ' + (s < 3 ? 'just now' : s < 60 ? s + 's' : Math.round(s / 60) + 'm');
    }
    setInterval(function () {
      if (Math.random() < rate) {
        var grow = (2 + Math.random() * 11) * 1e6;
        state.bytes += grow;
        state.delta += grow;
        state.last = Date.now();
        if (state.delta > cap) {
          state.bytes = bytes0;
          state.delta = delta0;
        }
        var row = sizeEl.closest('.lrow');
        if (row && !reduced) {
          row.classList.add('flash');
          setTimeout(function () { row.classList.remove('flash'); }, 600);
        }
      }
      render();
    }, 1300 + Math.random() * 500);
    render();
  }

  if ($('#lr1size')) liveRow($('#lr1size'), $('#lr1delta'), $('#lr1when'), 1.57e9, 330.4e6, 0.75);
  if ($('#lr2size')) liveRow($('#lr2size'), $('#lr2delta'), $('#lr2when'), 412.6e6, 12.8e6, 0.25);

  /* the Live Activity exhibit gets its own feed */
  $$('#liveDemo .lrow').forEach(function (row, i) {
    var size = row.querySelector('[data-demo-size]');
    var delta = row.querySelector('[data-demo-delta]');
    var when = row.querySelector('[data-demo-when]');
    if (!size) return;
    var bases = [2.31e9, 612e6, 1.02e9, 9.4e9];
    var deltas = [128e6, 48.2e6, 212e6, 1.7e9];
    liveRow(size, delta, when, bases[i], deltas[i], [0.7, 0.45, 0.55, 0.2][i]);
  });

  /* ------------------------------------------------------ popover demo -- */

  var big = $('#bigNumber'), sub = $('#popSub');
  var cleanBtn = $('#cleanBtn'), cleanLabel = $('#cleanLabel');
  var rescanIcon = $('#rescanIcon');
  var freeEl = $('#freeSpace');
  var cleanRows = $$('.crow[data-clean]');

  var TOTAL = 120.3e6, FREE0 = 43.99e9;

  function setRow(row, cleaned) {
    var sizeEl = row.querySelector('.c-size');
    var check = row.querySelector('.check');
    if (cleaned) {
      sizeEl.textContent = '—';
      sizeEl.classList.add('empty');
      row.classList.add('dim');
      check.classList.add('off');
      check.querySelector('use').setAttribute('href', '#i-circle');
    } else {
      sizeEl.textContent = fmtBytes(+row.getAttribute('data-size'));
      sizeEl.classList.remove('empty');
      row.classList.remove('dim');
      check.classList.remove('off');
      check.querySelector('use').setAttribute('href', '#i-check-fill');
    }
  }

  async function demoLoop() {
    if (!big || reduced || scripted) return;
    for (;;) {
      await wait(4200);

      /* clean */
      cleanBtn.classList.add('busy');
      cleanLabel.textContent = 'Cleaning…';
      cleanRows.forEach(function (r) { r.classList.add('cleaning'); });
      await wait(1500);

      cleanRows.forEach(function (r) { r.classList.remove('cleaning'); setRow(r, true); });
      tween(TOTAL, 0, 900, function (v) { big.textContent = fmtBytes(v); });
      tween(FREE0, FREE0 + TOTAL, 900, function (v) { freeEl.textContent = fmtBytes(v) + ' free'; });
      sub.textContent = 'Last cleanup: 120.3 MB freed · 1.99 GB found in total';
      cleanBtn.classList.remove('busy');
      cleanLabel.textContent = 'Clean Selected';
      await wait(3600);

      /* rescan  the caches grew back; that's the whole point */
      rescanIcon.classList.add('spin');
      sub.textContent = 'Scanning…';
      await wait(1300);
      rescanIcon.classList.remove('spin');
      cleanRows.forEach(function (r) { setRow(r, false); });
      tween(0, TOTAL, 900, function (v) { big.textContent = fmtBytes(v); });
      tween(FREE0 + TOTAL, FREE0, 900, function (v) { freeEl.textContent = fmtBytes(v) + ' free'; });
      sub.textContent = '2 selected · 120.3 MB found in total';
    }
  }
  demoLoop();

  /* ---------------------------------------------------- learning exhibit -- */

  var learnBadge = $('#learnBadge'), learnCheck = $('#learnCheck'), learnLog = $('#learnLog');
  if (learnBadge && !reduced) {
    var logLines = $$('#learnLog > div');
    var phase = 0;
    setInterval(function () {
      phase = (phase + 1) % 4;
      logLines.forEach(function (l, i) { l.style.opacity = i < phase ? 1 : 0.35; });
      if (phase === 3) {
        learnBadge.textContent = 'learned';
        learnBadge.className = 'badge badge-learned';
        learnCheck.classList.remove('off');
        learnCheck.querySelector('use').setAttribute('href', '#i-check-fill');
      } else if (phase === 0) {
        learnBadge.textContent = 'new';
        learnBadge.className = 'badge badge-new';
        learnCheck.classList.add('off');
        learnCheck.querySelector('use').setAttribute('href', '#i-circle');
      }
    }, 2100);
  }

  /* -------------------------------------------------- sparkline drawing -- */

  var spark = $('#sparkPath');
  if (spark && 'IntersectionObserver' in window && !reduced) {
    var len = spark.getTotalLength();
    spark.style.strokeDasharray = len;
    spark.style.strokeDashoffset = len;
    new IntersectionObserver(function (entries, io) {
      if (entries[0].isIntersecting) {
        spark.style.transition = 'stroke-dashoffset 1.6s cubic-bezier(0.4, 0, 0.2, 1)';
        spark.style.strokeDashoffset = '0';
        io.disconnect();
      }
    }, { threshold: 0.4 }).observe(spark);
  }

  /* ------------------------------------------------------------- motion -- */

  if (window.gsap && !reduced && !scripted) {
    var gsap = window.gsap;
    if (window.ScrollTrigger) gsap.registerPlugin(window.ScrollTrigger);

    /* hero entrance  the desktop "powers on". The timeline is created
     * paused (from-states apply immediately, so nothing flashes) and only
     * plays once the glass textures exist: every animated surface is then
     * a finished, cached layer and the whole entrance is compositor work. */
    var tl = gsap.timeline({
      paused: true,
      defaults: { ease: 'power2.out' },
      onComplete: attachLens
    });
    tl.from('.menubar', { yPercent: -100, autoAlpha: 0, duration: 0.55 })
      .from('.hero-copy h1', { y: 34, autoAlpha: 0, duration: 0.7 }, '-=0.2')
      .from('.hero-sub', { y: 22, autoAlpha: 0, duration: 0.55 }, '-=0.42')
      .from('.hero-ctas, .hero-note', { y: 18, autoAlpha: 0, duration: 0.5, stagger: 0.08 }, '-=0.35')
      .from('.popover', { scale: 0.94, autoAlpha: 0, duration: 0.55, ease: 'back.out(1.6)' }, '-=0.5')
      .from('.dock', { y: 90, autoAlpha: 0, duration: 0.65, ease: 'power3.out', onComplete: aimArrow }, '-=0.55');

    var started = false;
    function play() {
      if (!started) { started = true; tl.play(); }
    }
    glassReady.then(play);
    setTimeout(play, 800); /* never hold the page hostage to a slow texture */

    /* exhibits rise as you reach them — set up off the critical path:
     * ScrollTrigger measures the page on init (forced reflow), and none of
     * these sections are visible above the fold anyway */
    if (window.ScrollTrigger) {
      var setupReveals = function () {
        $$('.reveal').forEach(function (el) {
          gsap.from(el, {
            y: 56,
            autoAlpha: 0,
            duration: 0.8,
            ease: 'power2.out',
            scrollTrigger: { trigger: el, start: 'top 82%', toggleActions: 'play none none none' }
          });
        });
      };
      if ('requestIdleCallback' in window) requestIdleCallback(setupReveals, { timeout: 1500 });
      else setTimeout(setupReveals, 300);
    }
  } else {
    glassReady.then(attachLens);
  }
})();

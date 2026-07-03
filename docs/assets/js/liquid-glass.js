/* Liquid Glass  zero-per-frame-cost recreation of the macOS material.
 *
 * Insight that makes this fast: every glass surface on this page sits over
 * ONE static, viewport-fixed wallpaper. So the "backdrop blur" never needs
 * to be computed live. Instead:
 *
 *   1. The wallpaper is blurred + saturated ONCE into an offscreen canvas.
 *   2. Every .glass element gets a viewport-sized <img> of that texture,
 *      clipped by the element, counter-translated so it lines up 1:1 with
 *      the wallpaper behind. Scrolling only rewrites a transform 
 *      compositor-only work, no filters, no layout, no paint.
 *   3. The popover's refraction (lensing) is a displacement-map SVG filter
 *      applied ONCE to its (frozen) texture  a regular `filter`, not
 *      `backdrop-filter`, so the result is rasterized a single time and
 *      then just composited.
 *
 * Compared to live backdrop-filter (which re-filters every glass surface
 * at device resolution on every scroll frame), this is effectively free.
 *
 * The displacement map itself is physically grounded (see kube.io
 * "Liquid Glass in the Browser"): inside a `bezel`-wide band along the rim
 * the backdrop is sampled INWARD along the convex-squircle bevel profile
 * (1-(1-u)^4)^(1/4)  maximal refraction at the rim, flat glass in the
 * middle, and no sampling outside the element (no edge streaks).
 */
(function () {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var XLINK = 'http://www.w3.org/1999/xlink';

  var WALLPAPER = 'assets/img/wallpaper-dark.webp';
  var BLUR = 14;        /* px, baked into the texture */
  var SATURATE = 1.7;   /* baked into the texture */
  var OVERSCAN = 48;    /* texture margin so canvas-blur edge fade stays offscreen */

  var ua = navigator.userAgent;
  var isSafari = /Safari\//.test(ua) && !/Chrom(e|ium)|Edg|OPR/.test(ua);
  var isFirefox = /Firefox\//.test(ua);
  /* SVG filters referenced from CSS `filter` on HTML content are reliable
   * in Chromium; Safari/Firefox get frost without lensing. */
  var LENS_OK = !isSafari && !isFirefox;

  var surfaces = [];   /* { el, img, veil, docX, docY, frozen } */
  var texURL = null, texW = 0, texH = 0;
  var built = false;
  var readyResolve;
  var ready = new Promise(function (r) { readyResolve = r; });

  /* ------------------------------------------------------ texture bake -- */

  var ctxFilterOK = (function () {
    try {
      var c = document.createElement('canvas').getContext('2d');
      c.filter = 'blur(2px)';
      return c.filter === 'blur(2px)';
    } catch (e) { return false; }
  })();

  /* crude but effective gaussian approximation for engines without
   * ctx.filter: bounce through a small canvas with smoothing on */
  function cheapBlur(canvas) {
    var w = canvas.width, h = canvas.height;
    var small = document.createElement('canvas');
    small.width = Math.max(1, Math.round(w / 8));
    small.height = Math.max(1, Math.round(h / 8));
    var sctx = small.getContext('2d');
    var ctx = canvas.getContext('2d');
    for (var i = 0; i < 2; i++) {
      sctx.drawImage(canvas, 0, 0, small.width, small.height);
      ctx.drawImage(small, 0, 0, w, h);
    }
  }

  function bakeTexture(image) {
    texW = window.innerWidth + OVERSCAN * 2;
    texH = window.innerHeight + OVERSCAN * 2;
    var canvas = document.createElement('canvas');
    canvas.width = texW;
    canvas.height = texH;
    var ctx = canvas.getContext('2d');

    /* cover-fit, mirroring the CSS `background: center / cover` */
    var s = Math.max(texW / image.naturalWidth, texH / image.naturalHeight);
    var dw = image.naturalWidth * s, dh = image.naturalHeight * s;
    if (ctxFilterOK) ctx.filter = 'saturate(' + SATURATE + ') blur(' + BLUR + 'px)';
    ctx.drawImage(image, (texW - dw) / 2, (texH - dh) / 2, dw, dh);
    if (!ctxFilterOK) cheapBlur(canvas);

    var old = texURL;
    return new Promise(function (resolve) {
      if (canvas.toBlob) {
        canvas.toBlob(function (blob) {
          texURL = blob ? URL.createObjectURL(blob) : canvas.toDataURL();
          resolve();
        }, 'image/jpeg', 0.92);
      } else {
        texURL = canvas.toDataURL('image/jpeg', 0.92);
        resolve();
      }
    }).then(function () {
      /* revoke the previous texture only after imgs re-point (resize path) */
      if (old && old.indexOf('blob:') === 0) {
        setTimeout(function () { URL.revokeObjectURL(old); }, 1000);
      }
    });
  }

  /* --------------------------------------------------------- surfaces -- */

  function makeSurface(el) {
    var tint = getComputedStyle(el).backgroundColor;
    var wrap = document.createElement('div');
    wrap.className = 'lg-surface';
    var img = document.createElement('img');
    img.className = 'lg-tex';
    img.alt = '';
    img.decoding = 'async';
    img.setAttribute('fetchpriority', 'high'); /* blob is instant, but this is the LCP element */
    img.src = texURL;
    var veil = document.createElement('div');
    veil.className = 'lg-veil';
    veil.style.background = tint;
    wrap.appendChild(img);
    wrap.appendChild(veil);
    el.insertBefore(wrap, el.firstChild);
    el.style.backgroundColor = 'transparent';
    return { el: el, wrap: wrap, img: img, veil: veil, docX: 0, docY: 0, frozen: false };
  }

  function sizeImgs() {
    for (var i = 0; i < surfaces.length; i++) {
      surfaces[i].img.style.width = texW + 'px';
      surfaces[i].img.style.height = texH + 'px';
      if (surfaces[i].img.src !== texURL) surfaces[i].img.src = texURL;
    }
  }

  /* one read pass, then one write pass  never interleaved */
  function measure() {
    var x = window.scrollX, y = window.scrollY;
    for (var i = 0; i < surfaces.length; i++) {
      var r = surfaces[i].el.getBoundingClientRect();
      surfaces[i].docX = r.left + x;
      surfaces[i].docY = r.top + y;
    }
    sync(true);
  }

  function place(s, x, y) {
    s.img.style.transform =
      'translate3d(' + (x - s.docX - OVERSCAN) + 'px,' + (y - s.docY - OVERSCAN) + 'px,0)';
  }

  var lastY = -1, lastX = -1;
  function sync(force) {
    var x = window.scrollX, y = window.scrollY;
    if (!force && y === lastY && x === lastX) return;
    lastY = y; lastX = x;
    for (var i = 0; i < surfaces.length; i++) {
      if (surfaces[i].frozen && !force) continue;
      /* frozen surfaces are pinned to their rest position */
      if (surfaces[i].frozen) place(surfaces[i], 0, 0);
      else place(surfaces[i], x, y);
    }
  }

  /* scroll → rAF loop that parks itself once the position settles */
  var raf = null;
  function tickScroll() {
    var moved = window.scrollY !== lastY || window.scrollX !== lastX;
    if (moved) sync(false);
    raf = moved ? requestAnimationFrame(tickScroll) : null;
  }
  function onScroll() {
    if (!raf) raf = requestAnimationFrame(tickScroll);
  }

  /* ------------------------------------------------- displacement lens -- */

  var svgRoot = null, uid = 0;
  function ensureDefs() {
    if (svgRoot) return;
    svgRoot = document.createElementNS(NS, 'svg');
    svgRoot.setAttribute('width', '0');
    svgRoot.setAttribute('height', '0');
    svgRoot.setAttribute('aria-hidden', 'true');
    svgRoot.style.position = 'fixed';
    svgRoot.style.left = '-9999px';
    document.body.appendChild(svgRoot);
  }

  function sdRoundRect(px, py, w, h, r) {
    var qx = Math.abs(px) - (w / 2 - r);
    var qy = Math.abs(py) - (h / 2 - r);
    var ax = qx > 0 ? qx : 0;
    var ay = qy > 0 ? qy : 0;
    return Math.sqrt(ax * ax + ay * ay) + Math.min(Math.max(qx, qy), 0) - r;
  }

  /* complement of Apple's convex squircle bevel: max at rim, fast decay */
  function bevelProfile(u) {
    var k = 1 - u;
    k = 1 - k * k * k * k;
    return 1 - Math.pow(k, 0.25);
  }

  function makeMap(w, h, r, bezel) {
    var canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    var ctx = canvas.getContext('2d');
    var img = ctx.createImageData(w, h);
    var data = img.data;
    var maxR = Math.min(w, h) / 2;
    var rad = Math.min(r, maxR);
    var band = Math.min(bezel, maxR);

    for (var y = 0; y < h; y++) {
      var py = y + 0.5 - h / 2;
      for (var x = 0; x < w; x++) {
        var px = x + 0.5 - w / 2;
        var d = sdRoundRect(px, py, w, h, rad);
        var nx = 0.5, ny = 0.5;
        if (d < 0 && d > -band) {
          var gx = sdRoundRect(px + 1, py, w, h, rad) - sdRoundRect(px - 1, py, w, h, rad);
          var gy = sdRoundRect(px, py + 1, w, h, rad) - sdRoundRect(px, py - 1, w, h, rad);
          var gl = Math.sqrt(gx * gx + gy * gy) || 1;
          var m = bevelProfile(-d / band);
          /* inward sampling: convex lens pulls the rim toward the middle,
           * and never reads beyond the element (no clamp streaks) */
          nx = 0.5 - (gx / gl) * m * 0.5;
          ny = 0.5 - (gy / gl) * m * 0.5;
        }
        var i = (y * w + x) * 4;
        data[i] = Math.round(nx * 255);
        data[i + 1] = Math.round(ny * 255);
        data[i + 2] = 128;
        data[i + 3] = 255;
      }
    }
    ctx.putImageData(img, 0, 0);
    return canvas.toDataURL('image/png');
  }

  function num(el, attr, fallback) {
    var v = parseFloat(el.getAttribute(attr));
    return isNaN(v) ? fallback : v;
  }

  /* Attach the refraction filter to an element's frozen texture. Applied as
   * a regular `filter` on static content → rasterized once, then cached. */
  function lens(el) {
    if (!LENS_OK || !el) return;
    var s = null;
    for (var i = 0; i < surfaces.length; i++) {
      if (surfaces[i].el === el) { s = surfaces[i]; break; }
    }
    if (!s) return;

    var r = el.getBoundingClientRect();
    var w = Math.round(r.width), h = Math.round(r.height);
    if (!w || !h) return;

    var radius = num(el, 'data-lg-radius', parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0);
    var bezel = num(el, 'data-lg-bezel', 18);
    var scale = num(el, 'data-lg-scale', 26);

    ensureDefs();
    var id = 'lg-lens-' + ++uid;
    var f = document.createElementNS(NS, 'filter');
    f.setAttribute('id', id);
    f.setAttribute('x', '0');
    f.setAttribute('y', '0');
    f.setAttribute('width', String(w));
    f.setAttribute('height', String(h));
    f.setAttribute('filterUnits', 'userSpaceOnUse');
    f.setAttribute('color-interpolation-filters', 'sRGB');

    var fi = document.createElementNS(NS, 'feImage');
    fi.setAttribute('x', '0');
    fi.setAttribute('y', '0');
    fi.setAttribute('width', String(w));
    fi.setAttribute('height', String(h));
    fi.setAttribute('preserveAspectRatio', 'none');
    fi.setAttribute('result', 'map');
    fi.setAttributeNS(XLINK, 'href', makeMap(w, h, radius, bezel));
    f.appendChild(fi);

    var disp = document.createElementNS(NS, 'feDisplacementMap');
    disp.setAttribute('in', 'SourceGraphic');
    disp.setAttribute('in2', 'map');
    disp.setAttribute('scale', String(scale));
    disp.setAttribute('xChannelSelector', 'R');
    disp.setAttribute('yChannelSelector', 'G');
    f.appendChild(disp);

    svgRoot.appendChild(f);

    /* pin the texture to the element's rest position, then bend it */
    s.frozen = true;
    place(s, 0, 0);
    s.wrap.style.filter = 'url(#' + id + ')';
  }

  /* ------------------------------------------------------------ build -- */

  function build() {
    if (built) return ready;
    built = true;

    var image = new Image();
    image.src = WALLPAPER;
    var decoded = image.decode ? image.decode().catch(function () {}) :
      new Promise(function (r) { image.onload = r; image.onerror = r; });

    decoded
      .then(function () { return bakeTexture(image); })
      .then(function () {
        var els = document.querySelectorAll('.glass');
        for (var i = 0; i < els.length; i++) surfaces.push(makeSurface(els[i]));
        sizeImgs();
        measure();
        window.addEventListener('scroll', onScroll, { passive: true });
        var pending = null;
        window.addEventListener('resize', function () {
          clearTimeout(pending);
          pending = setTimeout(function () {
            bakeTexture(image).then(function () { sizeImgs(); measure(); });
          }, 200);
        });
        readyResolve();
      })
      .catch(function () { readyResolve(); /* graceful: tinted panels only */ });

    return ready;
  }

  window.LiquidGlass = { build: build, ready: ready, lens: lens };
})();

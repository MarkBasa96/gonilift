/* Gonilift website motion: scroll reveals, screenshot tilt + shine, cursor glow, lightbox.
   Loaded in <head> (not deferred) so the "motion" class is set before first paint.
   If this file never loads, nothing is hidden: the page simply stays still. */
(function () {
  var root = document.documentElement;
  var still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var mouse = matchMedia('(hover: hover) and (pointer: fine)').matches;
  if (!still && 'IntersectionObserver' in window) root.classList.add('motion');

  var REVEAL = 'section .eyebrow, section h2, section .sub, .faq-head > p, .feel .card, .feat8 .card, ' +
               '.shots8 figure, .plans .card, details.row, .posts .card, article > *';
  var GLOW = '.card, .btn, details, .frame';

  document.addEventListener('DOMContentLoaded', function () {
    // Screenshot frames: wrap each image so it can tilt and carry a light layer.
    // Done before the scroll reveal so the reveal watches the wrappers, not the moved images.
    function frame(img, cls) {
      var f = document.createElement('div');
      f.className = 'frame ' + cls;
      img.parentNode.insertBefore(f, img);
      f.appendChild(img);
      return f;
    }
    var hero = document.querySelector('.hero2 .tilt');
    if (hero) { var hf = frame(hero.querySelector('img'), 'tilt-card'); hero.classList.add('ready'); zoomable(hf); }
    document.querySelectorAll('.shots8 img').forEach(function (img) { zoomable(frame(img, 'shot-card')); });
    document.querySelectorAll('.feel-img').forEach(function (el) { el.classList.add('frame'); });
    document.querySelectorAll('article img').forEach(function (img) { zoomable(frame(img, 'post-shot')); });

    // Scroll reveal: whatever enters the screen together fades up in a short stagger.
    if (root.classList.contains('motion')) {
      var io = new IntersectionObserver(function (entries) {
        var n = 0;
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          var el = e.target;
          el.style.setProperty('--d', Math.min(n++, 5) * 0.07 + 's');
          el.classList.add('in');
          io.unobserve(el);
          setTimeout(function () { el.style.removeProperty('--d'); }, 1400);
        });
      }, { rootMargin: '0px 0px -6% 0px', threshold: 0.12 });
      document.querySelectorAll(REVEAL).forEach(function (el) { io.observe(el); });
    }

    // Tilt toward the mouse (desktop mouse only, never on touch or with reduced motion).
    function tilt(el, max) {
      var raf = 0;
      el.addEventListener('pointermove', function (e) {
        if (e.pointerType !== 'mouse') return;
        var r = el.getBoundingClientRect();
        var x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
        cancelAnimationFrame(raf);
        raf = requestAnimationFrame(function () {
          el.style.setProperty('--ry', (x * max).toFixed(2) + 'deg');
          el.style.setProperty('--rx', (-y * max).toFixed(2) + 'deg');
        });
      });
      el.addEventListener('pointerleave', function () {
        cancelAnimationFrame(raf);
        el.style.setProperty('--ry', '0deg');
        el.style.setProperty('--rx', '0deg');
      });
    }
    if (!still && mouse) {
      if (hero) tilt(hero, 12);
      document.querySelectorAll('.shot-card').forEach(function (f) { tilt(f, 10); });
    }

    // Cursor glow: every glowing layer under the pointer learns where the pointer is.
    document.addEventListener('pointermove', function (e) {
      for (var el = e.target; el && el.nodeType === 1; el = el.parentElement) {
        if (!el.matches(GLOW)) continue;
        var r = el.getBoundingClientRect();
        el.style.setProperty('--mx', (e.clientX - r.left) + 'px');
        el.style.setProperty('--my', (e.clientY - r.top) + 'px');
      }
    }, { passive: true });

    // Nav gets a deeper shadow once the page has scrolled.
    var nav = document.querySelector('nav');
    function onScroll() { nav.classList.toggle('scrolled', scrollY > 8); }
    if (nav) { onScroll(); addEventListener('scroll', onScroll, { passive: true }); }

    // Lightbox: click or tap a screenshot to see it large. Esc, click or tap closes it.
    var box;
    function zoomable(el) {
      var img = el.tagName === 'IMG' ? el : el.querySelector('img');
      el.classList.add('zoomable');
      el.tabIndex = 0;
      el.setAttribute('role', 'button');
      el.setAttribute('aria-label', 'Enlarge: ' + img.alt);
      function open() {
        if (!box) {
          box = document.createElement('dialog');
          box.className = 'lb';
          box.innerHTML = '<img alt=""><p></p>';
          box.addEventListener('click', function () { box.close(); });
          document.body.appendChild(box);
        }
        box.querySelector('img').src = img.currentSrc || img.src;
        box.querySelector('img').alt = img.alt;
        var cap = el.closest('figure') && el.closest('figure').querySelector('figcaption');
        box.querySelector('p').innerHTML = cap ? cap.innerHTML : '';
        box.showModal();
      }
      el.addEventListener('click', open);
      el.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); }
      });
    }
  });
})();

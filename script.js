/* ========================================================
   RAWAAN — Interactive Scripts
   ======================================================== */

(function () {
  'use strict';

  /* ---------- DOM References ---------- */
  const navbar = document.getElementById('navbar');
  const navBurger = document.getElementById('navBurger');
  const mobileMenu = document.getElementById('mobileMenu');
  const navLinks = document.querySelectorAll('.navbar__link, .mobile-menu__link');
  const mobileMenuLinks = document.querySelectorAll('.mobile-menu__link, .mobile-menu__cta');
  const waitlistForm = document.getElementById('waitlistForm');
  const toast = document.getElementById('toast');
  const animatedValues = document.querySelectorAll('.market__circle-value, .market__card-value span');

  /* ---------- Navbar: Scroll Effect ---------- */
  let lastScroll = 0;

  function handleNavbarScroll() {
    const scrollY = window.scrollY;
    if (scrollY > 60) {
      navbar.classList.add('scrolled');
    } else {
      navbar.classList.remove('scrolled');
    }
    lastScroll = scrollY;
  }

  window.addEventListener('scroll', handleNavbarScroll, { passive: true });
  handleNavbarScroll();

  /* ---------- Mobile Menu ---------- */
  navBurger.addEventListener('click', function () {
    navBurger.classList.toggle('active');
    mobileMenu.classList.toggle('active');
    document.body.style.overflow = mobileMenu.classList.contains('active') ? 'hidden' : '';
  });

  mobileMenuLinks.forEach(function (link) {
    link.addEventListener('click', function () {
      navBurger.classList.remove('active');
      mobileMenu.classList.remove('active');
      document.body.style.overflow = '';
    });
  });

  /* ---------- Smooth Scroll for Anchor Links ---------- */
  document.querySelectorAll('a[href^="#"]').forEach(function (anchor) {
    anchor.addEventListener('click', function (e) {
      var targetId = this.getAttribute('href');
      if (targetId === '#') return;

      var targetEl = document.querySelector(targetId);
      if (!targetEl) return;

      e.preventDefault();

      var navHeight = navbar.offsetHeight;
      var targetPosition = targetEl.getBoundingClientRect().top + window.scrollY - navHeight - 20;

      window.scrollTo({
        top: targetPosition,
        behavior: 'smooth'
      });
    });
  });

  /* ---------- Active Nav Link Highlighting ---------- */
  var sections = document.querySelectorAll('section[id]');

  function highlightActiveLink() {
    var scrollPos = window.scrollY + 120;

    sections.forEach(function (section) {
      var sectionTop = section.offsetTop - navbar.offsetHeight - 40;
      var sectionHeight = section.offsetHeight;
      var sectionId = section.getAttribute('id');

      if (scrollPos >= sectionTop && scrollPos < sectionTop + sectionHeight) {
        navLinks.forEach(function (link) {
          link.classList.remove('active');
          if (link.getAttribute('href') === '#' + sectionId) {
            link.classList.add('active');
          }
        });
      }
    });
  }

  window.addEventListener('scroll', highlightActiveLink, { passive: true });

  /* ---------- Scroll Animations (Intersection Observer) ---------- */
  var animElements = document.querySelectorAll('.anim-fade-up');

  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          observer.unobserve(entry.target);
        }
      });
    }, {
      threshold: 0.1,
      rootMargin: '0px 0px -40px 0px'
    });

    animElements.forEach(function (el) {
      observer.observe(el);
    });
  } else {
    /* Fallback: show everything immediately */
    animElements.forEach(function (el) {
      el.classList.add('visible');
    });
  }

  /* ---------- Animated Counters ---------- */
  var countersAnimated = false;

  function animateCounters() {
    if (countersAnimated) return;

    var marketSection = document.getElementById('market');
    if (!marketSection) return;

    var sectionTop = marketSection.getBoundingClientRect().top + window.scrollY;
    var sectionBottom = sectionTop + marketSection.offsetHeight;

    if (window.scrollY + window.innerHeight > sectionTop + 100 && window.scrollY < sectionBottom) {
      countersAnimated = true;

      animatedValues.forEach(function (el) {
        var target = parseFloat(el.getAttribute('data-count'));
        var prefix = el.getAttribute('data-prefix') || '';
        var suffix = el.getAttribute('data-suffix') || '';
        var duration = 2000;
        var startTime = null;

        function easeOutQuart(t) {
          return 1 - Math.pow(1 - t, 4);
        }

        function step(timestamp) {
          if (!startTime) startTime = timestamp;
          var elapsed = timestamp - startTime;
          var progress = Math.min(elapsed / duration, 1);
          var easedProgress = easeOutQuart(progress);
          var current = easedProgress * target;

          if (target >= 10) {
            el.textContent = prefix + Math.floor(current).toLocaleString() + suffix;
          } else {
            el.textContent = prefix + current.toFixed(1) + suffix;
          }

          if (progress < 1) {
            requestAnimationFrame(step);
          } else {
            el.textContent = prefix + (target >= 10 ? Math.floor(target).toLocaleString() : target.toFixed(1)) + suffix;
          }
        }

        requestAnimationFrame(step);
      });
    }
  }

  window.addEventListener('scroll', animateCounters, { passive: true });
  animateCounters();

  /* ---------- Problem Section Counters ---------- */
  var problemNumbers = document.querySelectorAll('.problem__card-number[data-count]');
  var problemCountersAnimated = false;

  function animateProblemCounters() {
    if (problemCountersAnimated) return;

    var problemSection = document.getElementById('problem');
    if (!problemSection) return;

    var sectionTop = problemSection.getBoundingClientRect().top + window.scrollY;
    var sectionBottom = sectionTop + problemSection.offsetHeight;

    if (window.scrollY + window.innerHeight > sectionTop + 100 && window.scrollY < sectionBottom) {
      problemCountersAnimated = true;

      problemNumbers.forEach(function (el) {
        var target = parseFloat(el.getAttribute('data-count'));
        var prefix = el.getAttribute('data-prefix') || '';
        var suffix = el.getAttribute('data-suffix') || '';
        var duration = 2000;
        var startTime = null;

        function easeOutQuart(t) {
          return 1 - Math.pow(1 - t, 4);
        }

        function step(timestamp) {
          if (!startTime) startTime = timestamp;
          var elapsed = timestamp - startTime;
          var progress = Math.min(elapsed / duration, 1);
          var easedProgress = easeOutQuart(progress);
          var current = easedProgress * target;

          if (target >= 10) {
            el.textContent = prefix + Math.floor(current).toLocaleString() + suffix;
          } else {
            el.textContent = prefix + current.toFixed(0) + suffix;
          }

          if (progress < 1) {
            requestAnimationFrame(step);
          } else {
            el.textContent = prefix + (target >= 10 ? Math.floor(target).toLocaleString() : target) + suffix;
          }
        }

        requestAnimationFrame(step);
      });
    }
  }

  window.addEventListener('scroll', animateProblemCounters, { passive: true });
  animateProblemCounters();

  /* ---------- Waitlist Form ---------- */
  if (waitlistForm) {
    waitlistForm.addEventListener('submit', function (e) {
      e.preventDefault();

      var emailInput = document.getElementById('waitlistEmail');
      var email = emailInput.value.trim();

      if (!email || !isValidEmail(email)) {
        emailInput.style.borderColor = '#ef4444';
        setTimeout(function () {
          emailInput.style.borderColor = '';
        }, 2000);
        return;
      }

      /* Simulate form submission */
      var submitBtn = waitlistForm.querySelector('.cta__submit');
      var originalText = submitBtn.textContent;
      submitBtn.textContent = 'Joining...';
      submitBtn.disabled = true;

      setTimeout(function () {
        emailInput.value = '';
        submitBtn.textContent = originalText;
        submitBtn.disabled = false;
        showToast();
      }, 1200);
    });
  }

  function isValidEmail(email) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
  }

  function showToast() {
    toast.classList.add('show');
    setTimeout(function () {
      toast.classList.remove('show');
    }, 4000);
  }

  /* ---------- Close Toast on Click ---------- */
  toast.addEventListener('click', function () {
    toast.classList.remove('show');
  });

  /* ---------- Navbar CTA Scroll ---------- */
  document.querySelectorAll('.navbar__cta, .mobile-menu__cta').forEach(function (btn) {
    btn.addEventListener('click', function (e) {
      /* Already handled by smooth scroll */
    });
  });

})();
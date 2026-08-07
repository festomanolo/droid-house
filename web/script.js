// DROIDHOUSE - Next-Level Promo Webpage Controller

document.addEventListener('DOMContentLoaded', () => {
    initSplashScreen();
    initNavbarScroll();
    initAppleImacScrollZoom();
    initScrollReveal();
    initShowcaseTabs();
});

// Splash Screen Timer & Dismissal
function initSplashScreen() {
    const splash = document.getElementById('splashScreen');
    if (!splash) return;

    // Fade out splash screen after 2.4 seconds
    setTimeout(() => {
        splash.classList.add('fade-out');
    }, 2400);

    // Dismiss on scroll or keydown as well
    const dismissSplash = () => {
        if (!splash.classList.contains('fade-out')) {
            splash.classList.add('fade-out');
        }
    };

    window.addEventListener('scroll', dismissSplash, { once: true });
    window.addEventListener('keydown', dismissSplash, { once: true });
}

// Navbar Scrolled State
function initNavbarScroll() {
    const navbar = document.querySelector('.navbar');
    if (!navbar) return;

    window.addEventListener('scroll', () => {
        if (window.scrollY > 40) {
            navbar.classList.add('scrolled');
        } else {
            navbar.classList.remove('scrolled');
        }
    });
}

// Apple.com/imac Scroll-Driven Zoom-In Animation
function initAppleImacScrollZoom() {
    const imacWrapper = document.getElementById('imacMockup');
    if (!imacWrapper) return;

    window.addEventListener('scroll', () => {
        const stage = document.querySelector('.hero-stage');
        if (!stage) return;

        const rect = stage.getBoundingClientRect();
        const windowHeight = window.innerHeight;

        // Calculate scroll progress relative to viewport
        if (rect.top <= windowHeight && rect.bottom >= 0) {
            const scrollProgress = Math.min(1, Math.max(0, (windowHeight - rect.top) / (windowHeight + rect.height)));
            
            // Apple iMac scroll zoom: scale smoothly from 0.88 to 1.05 as you scroll down
            const scale = 0.88 + (scrollProgress * 0.17); // 0.88 -> 1.05
            const translateY = (1 - scrollProgress) * 30; // 30px -> 0px

            imacWrapper.style.transform = `scale(${Math.min(1.06, scale)}) translateY(${translateY}px)`;
        }
    });
}

// Scroll Reveal Observer (Zoom-In Reveal)
function initScrollReveal() {
    const reveals = document.querySelectorAll('.reveal');
    
    const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
            if (entry.isIntersecting) {
                entry.target.classList.add('active');
            }
        });
    }, {
        threshold: 0.12,
        rootMargin: '0px 0px -40px 0px'
    });

    reveals.forEach((el) => observer.observe(el));
}

// Interactive Feature Showcase Tab Switcher
function initShowcaseTabs() {
    const tabs = document.querySelectorAll('.showcase-tab');
    const images = document.querySelectorAll('.showcase-img');

    tabs.forEach((tab) => {
        tab.addEventListener('click', () => {
            const targetId = tab.getAttribute('data-target');

            // Toggle Tab Active State
            tabs.forEach(t => t.classList.remove('active'));
            tab.classList.add('active');

            // Toggle Image Active State with scale transition
            images.forEach(img => {
                img.classList.remove('active');
                if (img.id === targetId) {
                    img.classList.add('active');
                }
            });
        });
    });
}

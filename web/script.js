// DROIDHOUSE - Next-Level Promo Webpage Interactive Controller

document.addEventListener('DOMContentLoaded', () => {
    initNavbarScroll();
    initIMacPerspectiveScroll();
    initScrollReveal();
    initShowcaseTabs();
    initTiltEffects();
});

// Navbar Scrolled State
function initNavbarScroll() {
    const navbar = document.querySelector('.navbar');
    window.addEventListener('scroll', () => {
        if (window.scrollY > 40) {
            navbar.classList.add('scrolled');
        } else {
            navbar.classList.remove('scrolled');
        }
    });
}

// Apple iMac 3D Scroll Perspective Animation
function initIMacPerspectiveScroll() {
    const imacWrapper = document.getElementById('imacMockup');
    if (!imacWrapper) return;

    window.addEventListener('scroll', () => {
        const stage = document.querySelector('.hero-stage');
        if (!stage) return;

        const rect = stage.getBoundingClientRect();
        const windowHeight = window.innerHeight;

        // Progress from top of viewport to center
        if (rect.top <= windowHeight && rect.bottom >= 0) {
            const scrollProgress = Math.min(1, Math.max(0, (windowHeight - rect.top) / (windowHeight + rect.height)));
            
            // Start tilted back 20deg, straighten to 0deg and scale up slightly on scroll
            const rotateX = 20 - (scrollProgress * 22); // 20deg -> -2deg
            const scale = 0.90 + (scrollProgress * 0.12); // 0.90 -> 1.02
            const translateY = (1 - scrollProgress) * 40; // 40px -> 0px

            imacWrapper.style.transform = `rotateX(${Math.max(0, rotateX)}deg) scale(${Math.min(1.02, scale)}) translateY(${translateY}px)`;
        }
    });
}

// Scroll Reveal Intersection Observer
function initScrollReveal() {
    const reveals = document.querySelectorAll('.reveal');
    
    const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
            if (entry.isIntersecting) {
                entry.target.classList.add('active');
            }
        });
    }, {
        threshold: 0.15,
        rootMargin: '0px 0px -50px 0px'
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

            // Toggle Tab Classes
            tabs.forEach(t => t.classList.remove('active'));
            tab.classList.add('active');

            // Toggle Image Classes
            images.forEach(img => {
                img.classList.remove('active');
                if (img.id === targetId) {
                    img.classList.add('active');
                }
            });
        });
    });
}

// Subtle 3D Card Hover Tilt FX
function initTiltEffects() {
    const cards = document.querySelectorAll('.feature-card, .imac-mockup-wrapper');

    cards.forEach(card => {
        card.addEventListener('mousemove', (e) => {
            const rect = card.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;

            const centerX = rect.width / 2;
            const centerY = rect.height / 2;

            const rotateX = (y - centerY) / 25;
            const rotateY = (centerX - x) / 25;

            card.style.transform = `perspective(1000px) rotateX(${rotateX}deg) rotateY(${rotateY}deg) scale3d(1.02, 1.02, 1.02)`;
        });

        card.addEventListener('mouseleave', () => {
            if (card.classList.contains('imac-mockup-wrapper')) {
                card.style.transform = 'rotateX(0deg) scale(1)';
            } else {
                card.style.transform = 'perspective(1000px) rotateX(0deg) rotateY(0deg) scale3d(1, 1, 1)';
            }
        });
    });
}

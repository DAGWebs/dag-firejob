/* NUI front-end for DAG.Menu.

   Protocol (client -> UI), via SendNUIMessage:
     { action: 'open',  menu: { title, subtitle, breadcrumb, canGoBack, options: [...] } }
     { action: 'close' }
     { action: 'theme', theme: { accent, width, position } }

   Protocol (UI -> client), via fetch to the resource's NUI callbacks:
     select { index }   back {}   close {} */

(function () {
    'use strict';

    var ICONS = {
        chevron: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18l6-6-6-6"/></svg>',
        back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
        check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>',
        close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6L6 18M6 6l12 12"/></svg>',
        lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/></svg>',
        user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 00-4-4H8a4 4 0 00-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
        car: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12.4l1.8-4.5A2.5 2.5 0 017.1 6.3h9.8a2.5 2.5 0 012.3 1.6l1.8 4.5"/><path d="M3 12.4h18v4.2a1 1 0 01-1 1H4a1 1 0 01-1-1z"/><circle cx="7.4" cy="17.6" r="1.3"/><circle cx="16.6" cy="17.6" r="1.3"/></svg>',
        box: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16V8l-9-5-9 5v8l9 5 9-5z"/><path d="M3.3 7.5L12 12l8.7-4.5M12 12v9"/></svg>',
        cash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/></svg>',
        wrench: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 000 1.4l1.6 1.6a1 1 0 001.4 0l3.77-3.77a6 6 0 01-7.94 7.94l-6.91 6.91a2.12 2.12 0 01-3-3l6.91-6.91a6 6 0 017.94-7.94l-3.76 3.76z"/></svg>',
        info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 16v-4M12 8h.01"/></svg>'
    };

    var root = document.getElementById('root');
    var titleEl = document.getElementById('title');
    var subtitleEl = document.getElementById('subtitle');
    var breadcrumbEl = document.getElementById('breadcrumb');
    var optionsEl = document.getElementById('options');
    var hintBack = document.getElementById('hintBack');

    var state = { menu: null, active: -1, open: false };

    function post(name, payload) {
        var resource = (typeof GetParentResourceName === 'function')
            ? GetParentResourceName()
            : 'dag-template';

        return fetch('https://' + resource + '/' + name, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(payload || {})
        }).catch(function () { /* standalone preview has no NUI host */ });
    }

    function icon(name) {
        if (!name) return '';
        if (ICONS[name]) return ICONS[name];
        // Anything not in the built-in set renders as text, so emoji work.
        return escapeHtml(name);
    }

    function escapeHtml(value) {
        return String(value).replace(/[&<>"']/g, function (char) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char];
        });
    }

    /* Rows that cannot be chosen: separators and disabled entries. */
    function isSelectable(option) {
        return !option.header && !option.disabled;
    }

    function firstSelectable(from, direction) {
        var options = state.menu.options;
        for (var step = 0; step < options.length; step += 1) {
            var index = (from + direction * step + options.length * 2) % options.length;
            if (isSelectable(options[index])) return index;
        }
        return -1;
    }

    function render() {
        var menu = state.menu;
        optionsEl.innerHTML = '';

        titleEl.textContent = menu.title || 'Menu';
        subtitleEl.textContent = menu.subtitle || '';
        subtitleEl.hidden = !menu.subtitle;
        breadcrumbEl.textContent = menu.breadcrumb || '';
        breadcrumbEl.hidden = !menu.breadcrumb;
        hintBack.hidden = !menu.canGoBack;

        if (!menu.options.length) {
            var empty = document.createElement('li');
            empty.className = 'menu__empty';
            empty.textContent = 'Nothing available.';
            optionsEl.appendChild(empty);
            return;
        }

        menu.options.forEach(function (option, index) {
            optionsEl.appendChild(renderOption(option, index));
        });

        scrollActiveIntoView();
    }

    function renderOption(option, index) {
        var item = document.createElement('li');
        item.className = 'option';
        item.dataset.index = String(index);
        item.setAttribute('role', 'menuitem');

        if (option.header) {
            item.classList.add('option--header');
            item.innerHTML = '<div class="option__text"><div class="option__title">'
                + escapeHtml(option.title || '') + '</div></div>';
            return item;
        }

        if (option.disabled) {
            item.classList.add('option--disabled');
            item.setAttribute('aria-disabled', 'true');
        }
        if (index === state.active) item.classList.add('option--active');

        var html = '<div class="option__icon">' + icon(option.icon || 'info') + '</div>';

        html += '<div class="option__text"><div class="option__title">'
            + escapeHtml(option.title || '') + '</div>';
        if (option.description) {
            html += '<div class="option__description">' + escapeHtml(option.description) + '</div>';
        }
        html += '</div>';

        html += '<div class="option__aside">';
        if (option.badge) {
            var tone = option.badgeTone ? ' option__badge--' + escapeHtml(option.badgeTone) : '';
            html += '<span class="option__badge' + tone + '">' + escapeHtml(option.badge) + '</span>';
        }
        if (option.submenu) {
            html += '<span class="option__chevron">' + ICONS.chevron + '</span>';
        }
        html += '</div>';

        if (typeof option.progress === 'number') {
            var pct = Math.max(0, Math.min(100, option.progress));
            html += '<div class="option__meter"><span style="width:' + pct + '%"></span></div>';
        }

        item.innerHTML = html;
        return item;
    }

    function setActive(index) {
        if (index === state.active) return;
        state.active = index;

        Array.prototype.forEach.call(optionsEl.children, function (child) {
            child.classList.toggle('option--active', Number(child.dataset.index) === index);
        });
        scrollActiveIntoView();
    }

    function scrollActiveIntoView() {
        var el = optionsEl.querySelector('.option--active');
        if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
    }

    function move(direction) {
        if (!state.menu || !state.menu.options.length) return;
        var next = firstSelectable(state.active + direction, direction);
        if (next !== -1) setActive(next);
    }

    function choose(index) {
        if (!state.menu) return;
        var option = state.menu.options[index];
        if (!option || !isSelectable(option)) return;
        setActive(index);
        post('select', { index: index + 1 });
    }

    function open(menu) {
        state.menu = {
            title: menu.title,
            subtitle: menu.subtitle,
            breadcrumb: menu.breadcrumb,
            canGoBack: !!menu.canGoBack,
            options: Array.isArray(menu.options) ? menu.options : []
        };
        state.active = -1;
        state.open = true;

        root.hidden = false;
        render();

        var first = firstSelectable(0, 1);
        if (first !== -1) setActive(first);

        // Next frame, so the entry transition actually runs.
        requestAnimationFrame(function () { root.dataset.open = 'true'; });
    }

    function close(notify) {
        if (!state.open) return;
        state.open = false;
        root.dataset.open = 'false';

        window.setTimeout(function () {
            if (!state.open) root.hidden = true;
        }, 160);

        if (notify !== false) post('close', {});
    }

    function applyTheme(theme) {
        if (!theme) return;
        if (theme.accent) {
            root.style.setProperty('--menu-accent', theme.accent);
            root.style.setProperty('--menu-accent-soft', hexToSoft(theme.accent));
        }
        if (theme.width) root.style.setProperty('--menu-width', theme.width + 'px');
        if (theme.position) root.dataset.position = theme.position;
    }

    function hexToSoft(hex) {
        var match = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
        if (!match) return 'rgba(76, 141, 255, 0.16)';
        return 'rgba(' + parseInt(match[1], 16) + ', ' + parseInt(match[2], 16)
            + ', ' + parseInt(match[3], 16) + ', 0.16)';
    }

    optionsEl.addEventListener('click', function (event) {
        var item = event.target.closest('.option');
        if (item) choose(Number(item.dataset.index));
    });

    optionsEl.addEventListener('mousemove', function (event) {
        var item = event.target.closest('.option');
        if (!item) return;
        var index = Number(item.dataset.index);
        if (isSelectable(state.menu.options[index])) setActive(index);
    });

    document.addEventListener('keydown', function (event) {
        if (!state.open) return;

        switch (event.key) {
            case 'ArrowUp':    event.preventDefault(); move(-1); break;
            case 'ArrowDown':  event.preventDefault(); move(1); break;
            case 'Enter':      event.preventDefault(); choose(state.active); break;
            case 'Backspace':
                event.preventDefault();
                if (state.menu.canGoBack) post('back', {}); else close();
                break;
            case 'Escape':     event.preventDefault(); close(); break;
            default: break;
        }
    });

    window.addEventListener('message', function (event) {
        var data = event.data || {};
        if (data.action === 'open') { applyTheme(data.theme); open(data.menu || {}); }
        else if (data.action === 'close') close(false);
        else if (data.action === 'theme') applyTheme(data.theme);
    });

    // Exposed for the offline preview in tests/ui.
    window.__dagMenu = { open: open, close: close, applyTheme: applyTheme, state: state };
})();

'use strict';
'require baseclass';

var dispose = null;
var paths = {
	mesh: 'M12 3 3 8v8l9 5 9-5V8l-9-5Zm0 0v9m-9 4 9-4 9 4M3 8l9 4 9-4m-9 4v9',
	status: 'M3 12h4l3-8 4 16 3-8h4',
	settings: 'M4 7h16M4 17h16M9 4v6m6 4v6',
	link: 'm10 13 4-4m-6 6-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m2 3 1-1a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0',
	clients: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2m20 0v-2a4 4 0 0 0-3-3.9M9 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8Zm8 .1a4 4 0 0 1 0 7.8',
	mlo: 'M4 6h16M4 12h16M4 18h16M8 3v6m8 0v6m-8 0v6',
	refresh: 'M20 7v5h-5M4 17v-5h5m-4-4a8 8 0 0 1 13-3l2 2M4 17l2 2a8 8 0 0 0 13-3',
	wifi: 'M2 8a16 16 0 0 1 20 0M5 12a11 11 0 0 1 14 0m-11 4a6 6 0 0 1 8 0m-4 4h.01',
	copy: 'M8 8h12v13H8V8ZM16 8V3H3v13h5',
	arrow: 'm9 5 7 7-7 7'
};

function icon(name) {
	var node = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	[ [ 'viewBox', '0 0 24 24' ], [ 'fill', 'none' ], [ 'stroke', 'currentColor' ],
		[ 'stroke-width', '1.7' ], [ 'stroke-linecap', 'round' ], [ 'stroke-linejoin', 'round' ],
		[ 'class', 'em-icon' ], [ 'aria-hidden', 'true' ] ].forEach(function(pair) { node.setAttribute(pair[0], pair[1]); });
	var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
	path.setAttribute('d', paths[name] || paths.mesh);
	node.appendChild(path);
	return node;
}

function mount(node) {
	if (!document.getElementById('em-styles')) document.head.appendChild(E('link', {
		'id': 'em-styles', 'rel': 'stylesheet', 'href': L.resource('easymesh-mtk/style.css')
	}));
	if (dispose) dispose();
	document.body.classList.add('em-active');
	var observer, menuObserver, media = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
	function brightness(el, property) {
		var match = getComputedStyle(el)[property].match(/^rgba?\(([^)]+)\)$/);
		if (!match) return null;
		var c = match[1].split(',').map(Number);
		return c.length > 3 && c[3] === 0 ? null : .299 * c[0] + .587 * c[1] + .114 * c[2];
	}
	function theme() {
		var html = document.documentElement, body = document.body;
		var bg = brightness(body, 'backgroundColor');
		if (bg === null) bg = brightness(html, 'backgroundColor');
		var fg = brightness(body, 'color');
		var marked = html.classList.contains('dark') || body.classList.contains('dark') ||
			html.getAttribute('data-darkmode') === 'true' || html.getAttribute('data-theme') === 'dark' ||
			html.getAttribute('data-argon-mode') === 'dark';
		var dark = marked || (bg !== null && bg < 128) || (fg !== null && fg > 140);
		node.classList.toggle('em-dark', dark);
		body.classList.toggle('em-dark', dark);
	}
	function nativeTabs() {
		document.querySelectorAll('#tabmenu a[href]').forEach(function(a) {
			if (/\/admin\/network\/easymesh\/(?:status|settings|onboarding|clients|mlo)(?:[/?#]|$)/.test(a.getAttribute('href'))) {
				var list = a.closest('ul.tabs');
				if (list) list.classList.add('em-native-tabs');
			}
		});
		var menu = document.getElementById('tabmenu');
		if (menu) {
			var lists = Array.from(menu.querySelectorAll('ul.tabs'));
			menu.classList.toggle('em-native-menu', lists.length > 0 && lists.every(function(list) { return list.classList.contains('em-native-tabs'); }));
		}
	}
	function cleanup() {
		if (observer) observer.disconnect();
		if (menuObserver) menuObserver.disconnect();
		if (media && media.removeEventListener) media.removeEventListener('change', theme);
		window.removeEventListener('pagehide', cleanup);
		document.body.classList.remove('em-active', 'em-dark');
		document.querySelectorAll('.em-native-tabs').forEach(function(n) { n.classList.remove('em-native-tabs'); });
		var menu = document.getElementById('tabmenu');
		if (menu) menu.classList.remove('em-native-menu');
	}
	dispose = cleanup;
	theme();
	nativeTabs();
	observer = new MutationObserver(theme);
	observer.observe(document.documentElement, { attributes: true, attributeFilter: [ 'class', 'style', 'data-theme', 'data-darkmode', 'data-argon-mode' ] });
	observer.observe(document.body, { attributes: true, attributeFilter: [ 'class', 'style', 'data-theme', 'data-darkmode' ] });
	var menu = document.getElementById('tabmenu');
	if (menu) { menuObserver = new MutationObserver(nativeTabs); menuObserver.observe(menu, { childList: true, subtree: true }); }
	if (media && media.addEventListener) media.addEventListener('change', theme);
	window.addEventListener('pagehide', cleanup);
	return node;
}

return baseclass.extend({
	icon: icon,
	page: function(active, subtitle, children, actions) {
		var pages = [ [ 'status', _('Overview'), 'status' ], [ 'settings', _('Settings'), 'settings' ],
			[ 'onboarding', _('Add node'), 'link' ], [ 'mlo', 'MLO', 'mlo' ] ];
		return mount(E('div', { 'class': 'em-page', 'data-em-page': active }, [
			E('div', { 'class': 'em-header' }, [
				E('div', { 'class': 'em-brand' }, [ E('span', { 'class': 'em-brand-icon' }, icon('mesh')),
					E('div', {}, [ E('h2', {}, _('EasyMesh')), E('p', { 'class': 'em-subtitle' }, subtitle) ]) ]),
				E('div', { 'class': 'em-actions' }, actions || [])
			]),
			E('nav', { 'class': 'em-nav', 'aria-label': _('EasyMesh') }, pages.map(function(p) {
				return E('a', { 'class': 'em-nav-item' + (active === p[0] ? ' is-active' : ''),
					'href': L.url('admin', 'network', 'easymesh', p[0]), 'aria-current': active === p[0] ? 'page' : null },
					[ icon(p[2]), E('span', {}, p[1]) ]);
			})),
			E('div', { 'class': 'em-content' }, children)
		]));
	},
	card: function(title, children, note, tools) {
		return E('section', { 'class': 'em-card' }, [
			E('div', { 'class': 'em-card-head' }, [ E('div', {}, [ E('h3', {}, title), note ? E('p', { 'class': 'em-note' }, note) : '' ]), tools || '' ]),
			E('div', { 'class': 'em-card-body' }, children)
		]);
	},
	details: function(title, children, note) {
		return E('details', { 'class': 'em-card em-details' }, [ E('summary', {}, [
			E('span', {}, [ E('strong', {}, title), note ? E('span', { 'class': 'em-note' }, note) : '' ]), icon('arrow')
		]), E('div', { 'class': 'em-details-body' }, children) ]);
	},
	badge: function(label, tone) {
		return E('span', { 'class': 'em-badge em-badge-' + (tone || 'neutral') }, [ E('i', {}), label ]);
	},
	button: function(label, handler, variant, glyph) {
		return E('button', { 'type': 'button', 'class': 'btn cbi-button em-button em-button-' + (variant || 'secondary'), 'click': handler },
			[ glyph ? icon(glyph) : '', E('span', {}, label) ]);
	},
	metric: function(label, value, note) {
		return E('div', { 'class': 'em-metric' }, [ E('span', { 'class': 'em-label' }, label),
			E('strong', { 'class': 'em-metric-value' }, value == null || value === '' ? '—' : value),
			note ? E('span', { 'class': 'em-note' }, note) : '' ]);
	},
	empty: function(title, note, glyph) {
		return E('div', { 'class': 'em-empty' }, [ icon(glyph || 'mesh'), E('strong', {}, title), note ? E('p', {}, note) : '' ]);
	},
	output: function(text) {
		return text && text.trim() ? E('pre', { 'class': 'em-output', 'tabindex': 0 }, text) : this.empty(_('No data yet'), '', 'link');
	},
	busy: function(button, task) {
		if (button.disabled) return Promise.resolve();
		button.disabled = true;
		button.classList.add('spinning');
		button.setAttribute('aria-busy', 'true');
		return Promise.resolve().then(task).finally(function() {
			button.disabled = false;
			button.classList.remove('spinning');
			button.removeAttribute('aria-busy');
		});
	},
	role: function(value) { return value === '1' ? _('Controller') : value === '2' ? _('Agent') : _('Auto'); },
	band: function(value) { return ({ '2g': '2.4 GHz', '2.4g': '2.4 GHz', '5g': '5 GHz', '6g': '6 GHz' })[value] || value || '—'; }
});

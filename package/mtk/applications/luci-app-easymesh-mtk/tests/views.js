/* SPDX-License-Identifier: GPL-2.0-only */
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const db = {
	wireless: {
		r0: { '.name': 'r0', '.type': 'wifi-device', type: 'mtwifi', band: '2g', map_mode: '0' },
		r1: { '.name': 'r1', '.type': 'wifi-device', type: 'mtwifi', band: '5g', map_mode: '0' },
		ap0: { '.name': 'ap0', '.type': 'wifi-iface', device: 'r0', mode: 'ap', ssid: 'Mesh' }
	},
	mapd: { mapd_cfg: { '.name': 'mapd_cfg', '.type': 'mapd_cfg', enable: '0', DeviceRole: '2' } },
	'1905d_cfg': { map: { '.name': 'map', '.type': 'iface', map_ver: 'R3' } }
};
const loads = [], maps = [], calls = [], polls = [];
const uci = {
	load: name => { loads.push(name); return Promise.resolve(); },
	get: (name, section, key) => db[name]?.[section]?.[key],
	set: (name, section, key, value) => { (db[name] ||= {}); (db[name][section] ||= {})[key] = value; },
	unset: (name, section, key) => { delete db[name]?.[section]?.[key]; },
	sections: (name, kind) => Object.values(db[name] || {}).filter(item => item['.type'] === kind)
};
class Map {
	constructor(config) { this.config = config; this.sections = []; this.chains = []; maps.push(this); }
	chain(config) { this.chains.push(config); }
	section(kind, name) { const section = new Section(this, name, kind); this.sections.push(section); return section; }
	render() { return Promise.resolve(E('div')); }
}
class Section {
	constructor(map, name, kind) { this.map = map; this.name = name; this.kind = kind; this.options = []; }
	tab() {}
	option(kind, name) { const option = { name, kind, values: [], depends() {}, value(k, title) { this.values.push(k); } }; this.options.push(option); return option; }
	taboption(tab, kind, name) { return this.option(kind, name); }
}
const form = { Map, NamedSection: 'named', GridSection: 'grid', Flag: 'flag', ListValue: 'list', Value: 'value', DummyValue: 'dummy' };
function E(tag, attrs, children) {
	if (Array.isArray(tag)) return E('fragment', {}, tag);
	if (attrs != null && (Array.isArray(attrs) || typeof attrs !== 'object')) { children = attrs; attrs = {}; }
	return { tag, attrs: attrs || {}, children: children == null ? [] : Array.isArray(children) ? children : [children], appendChild(node) { this.children.push(node); }, querySelectorAll(selector) { const out = []; function walk(n) { if (!n || typeof n !== 'object') return; if (n.tag === selector) out.push(n); (n.children || []).forEach(walk); } this.children.forEach(walk); return out; } };
}
String.prototype.format = function(...args) { let i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); };
const status = { ok: true, running: false, enable: '1', role: '2', svc_enabled: '1', mapd: 'stopped', p1905: 'stopped', wapp: 'stopped', socket: 'down' };
function expect(reply, schema) {
	if (!schema) return reply;
	const key = Object.keys(schema)[0];
	const value = key === '' ? reply : reply?.[key];
	return value != null && Object.prototype.toString.call(value) === Object.prototype.toString.call(schema[key]) ? value : schema[key];
}
const rpc = { declare: declaration => (...values) => {
	const params = {};
	(declaration.params || []).forEach((name, i) => { if (values[i] !== undefined) params[name] = values[i]; });
	calls.push({ method: declaration.method, params });
	const reply = declaration.method === 'get_status' ? status : declaration.method === 'get_clients' ? { ok: true, clients: [] } : { ok: true, uri: 'DPP:V:2;K:public;;' };
	return Promise.resolve(expect(reply, declaration.expect));
} };
const ui = { addNotification() {}, createHandlerFn: (ctx, fn) => fn.bind(ctx) };
const dom = { content: (node, children) => { node.children = Array.isArray(children) ? children : [children]; } };
const poll = { add: fn => { polls.push(fn); } };
const document = { getElementById: () => ({ value: 'DPP:V:2;K:public;;' }) };
// The visual shell is exercised by the native LuCI/Argon preview. Keep these
// fixtures focused on the existing form and RPC contracts.
const meshUI = {
 page: (name, subtitle, children) => E('div', {}, children),
 card: (title, children) => E('section', {}, [E('h3', {}, title)].concat(children)),
 details: (title, children) => E('details', {}, [E('summary', {}, title)].concat(children)),
 icon: () => E('span'), badge: label => E('span', {}, label),
 metric: (label, value) => E('div', {}, [label, value]),
 empty: label => E('div', {}, label), output: value => E('pre', {}, value || ''),
 button: (label, click) => E('button', { click }, label),
 busy: (button, task) => Promise.resolve().then(task),
 role: value => value === '1' ? 'Controller' : value === '2' ? 'Agent' : 'Auto',
 band: value => value || ''
};
function loadClients() {
 const code = fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/easymesh-mtk/clients.js'), 'utf8');
 return new Function('baseclass', 'meshUI', 'E', '_', code)({ extend: value => value }, meshUI, E, x => x);
}
function load(name) {
	const code = fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/easymesh-mtk', name + '.js'), 'utf8');
	return new Function('view', 'form', 'uci', 'rpc', 'ui', 'dom', 'poll', 'E', '_', 'L', 'document', 'window', 'meshUI', 'clientUI', code)(
		{ extend: value => value }, form, uci, rpc, ui, dom, poll, E, x => x, { bind: (fn, ctx) => fn.bind(ctx), url: (...parts) => '/' + parts.join('/') }, document, { location: { reload() {} } }, meshUI, loadClients());
}
const button = () => ({ currentTarget: { classList: { add() {}, remove() {} }, disabled: false } });
let checks = 0;
function check(value, label) { assert(value, label); console.log(`ok ${++checks} - ${label}`); }
function text(node) { return typeof node === 'string' ? node : (node?.children || []).map(text).join(' '); }
(async () => {
	const settings = load('settings'); await settings.load(); await settings.render();
	check(loads.includes('wireless') && loads.includes('mapd') && loads.includes('1905d_cfg'), 'settings load all used UCI configs');
	const main = maps.find(map => map.config === 'mapd');
	check(main.chains.includes('1905d_cfg') && main.chains.includes('wireless'), 'cross-config edits join the save transaction');
	const options = main.sections.flatMap(section => section.options);
	const enable = options.find(option => option.name === 'enable'); enable.write('mapd_cfg', '1');
	check(db.wireless.r0.map_mode === '1' && db.wireless.r1.map_mode === '1', 'enable propagates to participating radios');
	db.wireless.r1.map_mode = '0'; enable.write('mapd_cfg', '1');
	check(db.wireless.r1.map_mode === '0', 'saving an unchanged enable preserves per-radio exclusions');
	enable.write('mapd_cfg', '0');
	check(db.wireless.r0.map_mode === '0' && db.wireless.r1.map_mode === '0', 'a second save can disable MAP without reloading the page');
	const version = options.find(option => option.name === 'map_ver'); version.write('mapd_cfg', 'R2');
	check(db['1905d_cfg'].map.map_ver === 'R2' && !version.values.includes('R5'), 'MAP version edits are persisted and restricted to built support');
	const onboarding = load('onboarding'); await onboarding.load(); onboarding.render();
	check(loads.includes('mapd'), 'onboarding loads the device role');
	await onboarding.handleWps(button());
	check(calls.at(-1).params.action === 'wps' && calls.at(-1).params.band === 'all', 'WPS uses structured ubus arguments');
	await onboarding.handleDppEnroll(button());
	check(calls.at(-1).params.uri === 'DPP:V:2;K:public;;' && calls.at(-1).params.band === '', 'DPP URI occupies the declared URI parameter');
	await onboarding.handleDppUri(button());
	check(calls.at(-1).method === 'get_uri' && calls.at(-1).params.ifname === '', 'URI retrieval follows the ubus method signature');
	const view = load('status'), data = await view.load(), node = view.render(data);
	check(typeof data[0] === 'object' && data[0].enable === '1', 'status retains the complete RPC reply');
	check(text(view.panel).includes('Not ready') && !text(view.panel).includes('Running'), 'configured enable does not fabricate a running service');
	const clients = loadClients();
	check(Array.isArray(data[1].clients) && polls.length === 1, 'overview polls status and clients together');
	check(!text(clients.renderType({ is_mlo: 'No', is_backhaul: 'Unknown' })).includes('MLO'), 'a No string does not label a station as MLO');
	check(text(clients.renderType({ is_mlo: 'Yes', is_backhaul: 'Unknown' })).includes('MLO'), 'observed MLD stations retain the MLO label');
	check(text(clients.renderType({ is_backhaul: 'Unknown' })) === '—', 'unknown backhaul identity stays unclassified');
	check(text(clients.renderSignalBar('')) === '—', 'missing RSSI is not rendered as a measured signal');
	db.mapd.mapd_cfg.DeviceRole = '1';
	const previous = maps.length; const mlo = load('mlo'); await mlo.load(); await mlo.render();
	const added = maps.slice(previous), remote = added.find(map => map.config === 'mapd');
	check(remote.sections.some(section => section.kind === 'grid' && section.name === 'iface') && remote.sections.some(section => section.name === 'bh_sta'), 'MLO settings write the schemas consumed by the daemon adapter');
	check(!added.some(map => map.config === 'wireless') && !remote.sections.some(section => section.name === 'mld_ap' || section.name === 'mld_sta'), 'Mesh MLO profiles do not create a local wireless editor');
	console.log(`1..${checks}`);
})().catch(error => { console.error(error); process.exitCode = 1; });

#!/usr/bin/ucode
'use strict';

// SPDX-License-Identifier: GPL-2.0
/*
 * mtwifi netifd wireless driver handler (ucode)
 *
 * Copyright (C) 2026 nanchuci <nanchuci023@gmail.com>
 *
 * 用法（由 lib/netifd/wireless.uc 调用）：
 *   ./mtwifi.sh <type> dump
 *   ./mtwifi.sh <type> setup    <radioN> <payload-json>
 *   ./mtwifi.sh <type> teardown <radioN> <payload-json>
 * 因此 ARGV[1] = 操作，ARGV[2] = 设备段名，ARGV[3] = JSON。
 *
 * 与官方 mac80211.sh(ucode) 的集成方式：
 *  - dump/选项表：官方 schema + MTK 私有选项
 *  - BSS/hostapd 配置：复用官方 wifi.ap / wifi.iface
 *  - STA 配置：复用官方 wifi.supplicant.generate()，挂载走 wpa_cli
 *  - hostapd/wpa_supplicant 进程与 MTK .dat/L1 profile 由 mtwifi.* 模块处理
 */

import * as fs from 'fs';
import * as uci from 'uci';
import { validate } from 'wifi.validate';
import * as netifd from 'wifi.netifd';

import * as l1dat from 'mtwifi.l1dat';
import * as cfg from 'mtwifi.cfg';
import { validate_capabilities } from 'mtwifi.caps';
import { validate_profile, normalize_legacy_device } from 'mtwifi.validate';
import * as ifname from 'mtwifi.ifname';
import * as mt_hostapd from 'mtwifi.hostapd';
import * as mt_supplicant from 'mtwifi.supplicant';
import { log, trim, exists, shell_quote, sleep, readfile, atomic_write, rollback_files } from 'mtwifi.common';

global.radio = ARGV[2];

const REINSTALL_LOCK = '/tmp/mtwifi_reloading.lock';
const IFACE_WPS_FILE = '/var/run/mtwifi-iface-wps';
const REBUILD_QUEUE = '/var/run/mtwifi-rebuild.json';
const REBUILD_RESTORE = '/var/run/mtwifi-restore.json';
const REBUILD_STATUS = '/var/run/mtwifi-rebuild.status';
const REBUILD_TRANSACTION = '/var/run/mtwifi-rebuild.transaction';
const KINDS = [ 'device', 'iface', 'vlan', 'station' ];
const TYPE = { array: 1, string: 3, number: 5, boolean: 7 };

const SCHEMA_PATH = {
	device: '/usr/share/schema/wireless.wifi-device.json',
	iface: '/usr/share/schema/wireless.wifi-iface.json',
	vlan: '/usr/share/schema/wireless.wifi-vlan.json',
	station: '/usr/share/schema/wireless.wifi-station.json',
};

/*
 * MTK 私有选项（官方 schema 里没有的）。
 * 官方 schema 已有的键以 schema 为准，这里只补差集。
 */
const EXTRA = {
	device: [
		[ 'devname', TYPE.string ],
		[ 'dbdc_main', TYPE.boolean ],
		[ 'rsn_overriding', TYPE.boolean ],
		[ 'whnat', TYPE.boolean ],
		[ 'acs_alg', TYPE.number ],
		[ 'acs_skiplist', TYPE.array ],
		[ 'psc_acs', TYPE.boolean ],
		[ 'twt', TYPE.number ],
		[ 'eht_restricted_twt', TYPE.boolean ],
		[ 'tx_burst', TYPE.boolean ],
		[ 'tx_preamble', TYPE.number ],
		[ 'doth', TYPE.boolean ],
		[ 'dfs', TYPE.boolean ],
		[ 'zw_dfs', TYPE.boolean ],
		[ 'vendor_vht', TYPE.boolean ],
		[ 'vht_1024', TYPE.boolean ],
		[ 'he_ldpc', TYPE.boolean ],
		[ 'mu_beamformer', TYPE.boolean ],
		[ 'itxbfen', TYPE.boolean ],
		[ 'sre_enable', TYPE.boolean ],
		[ 'vow_airtime_fairness_en', TYPE.boolean ],
		[ 'map_mode', TYPE.number ],
		[ 'obss_interval', TYPE.number ],
		[ 'eht_bw320_offset', TYPE.number ],
	],
	iface: [
		[ 'mldgroup', TYPE.number ],
		[ 'rsn_overriding', TYPE.boolean ],
		[ 'rsn_override', TYPE.number ],
		[ 'ieee80211w', TYPE.number ],
		[ 'mwds', TYPE.boolean ],
		[ 'mac_repeater', TYPE.boolean ],
		[ 'disable_eht', TYPE.boolean ],
		[ 'amsdu', TYPE.boolean ],
		[ 'autoba', TYPE.boolean ],
		[ 'uapsd', TYPE.boolean ],
		[ 'reliable_11r', TYPE.boolean ],
		[ 'mumimo_dl', TYPE.boolean ],
		[ 'mumimo_ul', TYPE.boolean ],
		[ 'ofdma_dl', TYPE.boolean ],
		[ 'ofdma_ul', TYPE.boolean ],
		[ 'frag', TYPE.number ],
		[ 'rts', TYPE.number ],
		[ 'kicklow', TYPE.number ],
		[ 'assocthres', TYPE.number ],
	],
	vlan: [],
	station: [],
};

/* ------------------------------------------------------------------ */
/* dump：输出本驱动的选项表                                            */
/* ------------------------------------------------------------------ */

function schema_properties(kind) {
	let text = readfile(SCHEMA_PATH[kind]);

	if (!text) {
		log(`cannot read ${SCHEMA_PATH[kind]}: wifi-scripts 的 ucode 覆盖层未安装？`);
		return {};
	}

	let data;

	try {
		data = json(text);
	} catch (e) {
		log(`failed to parse ${SCHEMA_PATH[kind]}: ${e}`);
		return {};
	}

	return data?.properties ?? {};
};

function dump_option(props, key) {
	let schema = props[key];
	let ref = (schema.type == 'alias') ? schema.default : key;
	let type = props[ref]?.type;

	if (!type || TYPE[type] == null) {
		log(`dropping unsupported option ${key} (type ${type})`);
		return null;
	}

	return [ key, TYPE[type] ];
};

function dump_options() {
	let dump = { name: 'mtwifi' };

	for (let kind in KINDS) {
		let props = schema_properties(kind);
		let seen = {};
		let list = [];

		for (let key in props) {
			let opt = dump_option(props, key);

			if (opt) {
				seen[opt[0]] = true;
				push(list, opt);
			}
		}

		for (let opt in EXTRA[kind])
			if (!seen[opt[0]])
				push(list, opt);

		dump[kind] = list;
	}

	printf('%J\n', dump);

	return 0;
};

/* ------------------------------------------------------------------ */
/* payload 辅助                                                        */
/* ------------------------------------------------------------------ */

function vif_keys(payload) {
	return sort(keys(payload.interfaces ?? {}));
};

function for_each_vif(payload, mode, cb) {
	for (let k in vif_keys(payload)) {
		let v = payload.interfaces[k];

		if (v?.config && (!mode || v.config.mode == mode))
			cb(k, v);
	}
};

function find_radio_section(devname) {
	let config = uci.cursor().get_all('wireless') ?? {};

	for (let name, section in config)
		if (section['.type'] == 'wifi-device' && section.devname == devname)
			return name;

	return null;
};

/*
 * devname 解析：
 *  1. 新配置：wifi-device 段里的 devname 选项
 *  2. 旧配置：段名直接就是 L1 profile 里的 devname
 */
function resolve_devname(l1, payload, section) {
	let devname = payload.config?.devname;

	if (devname)
		return devname;

	if (l1 && l1[l1dat.DEV_RINDEX][section])
		return section;

	return null;
};

/* MTK 私有键在 validate() 之前摘掉，避免官方 schema 报 “not present” */
function validate_kind(kind, config, extras) {
	let saved = {};
	/* Vendor options sharing a schema name must not acquire schema defaults
	 * or be consumed as unrelated aliases (tx_burst is a WMM alias upstream).
	 */
	let optional = {};

	for (let opt in extras) {
		let key = opt[0];
		optional[key] = true;

		if (config[key] != null) {
			saved[key] = opt[1] == TYPE.boolean ? !!+config[key] :
				opt[1] == TYPE.number ? +config[key] : config[key];
			if (opt[1] == TYPE.number && !(saved[key] >= -127 && saved[key] <= 65535))
				die('INVALID_VENDOR_OPTION');
			delete config[key];
		}
	}

	validate(kind, config);
	for (let key in optional)
		delete config[key];

	for (let key, value in saved)
		config[key] = value;
};

function sanitize_device(config) {
	let cell_density = config.cell_density != null ? +config.cell_density : null;

	if (cell_density != null) {
		let clamped = min(max(cell_density, 0), 3);

		if (clamped != cell_density) {
			log(`cell_density ${cell_density} out of range, clamped to ${clamped}`);
			config.cell_density = clamped;
		}
	}
};

function validate_device(config) {
	let saved = {};

	validate_kind('device', config, EXTRA.device);
	if (config.doth != null)
		config.ieee80211h = config.doth;

	for (let key, value in saved)
		config[key] = value;
};

function validate_ifaces(payload) {
	for_each_vif(payload, null, (k, v) => {
		validate_kind('iface', v.config, EXTRA.iface);
		for (let _, vlan in v.vlans ?? {})
			validate('vlan', vlan.config);
		for (let _, sta in v.stas ?? {})
			validate('station', sta.config);
	});
};

/* ------------------------------------------------------------------ */
/* phy 解析                                                            */
/* ------------------------------------------------------------------ */

function phy_of_ifname(ifname) {
	if (!ifname)
		return null;

	let link = fs.readlink(`/sys/class/net/${ifname}/phy80211`);

	if (link)
		return fs.basename(link);

	let name = trim(readfile(`/sys/class/net/${ifname}/phy80211/name`) ?? '');

	return length(name) ? name : null;
};

function resolve_phy(config, dev) {
	let expected = phy_of_ifname(dev?.main_ifname);
	if (expected && config.macaddr &&
	    lc(trim(readfile(`/sys/class/ieee80211/${expected}/macaddress`) ?? '')) != lc(config.macaddr))
		die('PHY_PROFILE_MISMATCH');
	if (expected && config.path) {
		let parts = split(config.path, '+');
		let devices = filter(fs.lsdir('/sys/class/ieee80211') ?? [], (name) => {
			let path = fs.realpath(`/sys/class/ieee80211/${name}/device`) ?? '';
			return substr(path, -length(parts[0])) == parts[0];
		});
		sort(devices, (a, b) => +readfile(`/sys/class/ieee80211/${a}/index`) -
			+readfile(`/sys/class/ieee80211/${b}/index`));
		if (devices[+parts[1]] != expected)
			die('PHY_PROFILE_MISMATCH');
	}
	return expected;
};

/* ------------------------------------------------------------------ */
/* setup                                                               */
/* ------------------------------------------------------------------ */

function read_json(path) {
	try { return json(readfile(path) ?? 'null'); }
	catch (e) { return null; }
};

function rebuild_source() {
	return sprintf('%J', uci.cursor().get_all('wireless') ?? {});
};

function spawn_rebuild() {
	return system('/usr/bin/ucode /lib/netifd/wireless/mtwifi.sh mtwifi rebuild >/dev/null 2>&1 &') == 0;
};

function queue_rebuild(record) {
	let source = rebuild_source();
	let queue = read_json(REBUILD_QUEUE);
	if (queue?.source != source)
		queue = { source, radios: {} };
	queue.radios[record.radio] = record;
	return atomic_write(REBUILD_QUEUE, sprintf('%J\n', queue)) && spawn_rebuild();
};

function rebuild_status(phase, error, recovered) {
	atomic_write(REBUILD_STATUS, sprintf('%J\n', { phase, error, recovered }));
};

function rebuild_inventory(records) {
	let config = {};
	for (let radio, record in records) {
		config[radio] = { ...record.payload.config, '.type': 'wifi-device', type: 'mtwifi' };
		for (let index, iface in record.payload.interfaces ?? {})
			config[iface.name ?? index] = { ...iface.config, '.type': 'wifi-iface', device: radio };
	}
	return config;
};

function rebuild_config_lock() {
	for (let attempt = 0; attempt < 200; attempt++) {
		let lock = fs.open('/var/run/mtwifi-config.lock', 'ae', 0600);
		if (!lock || !lock.lock('x')) die('CONFIG_LOCK_FAILED');
		let status = global.ubus.call('network.wireless', 'status');
		let pending = type(status) != 'object';
		for (let radio, config in uci.cursor().get_all('wireless') ?? {})
			if (config['.type'] == 'wifi-device' && config.type == 'mtwifi')
				pending ||= !!status?.[radio]?.pending;
		if (!pending) return lock;
		lock.close();
		sleep(0.1);
	}
	die('WIRELESS_BUSY');
};

function rebuild_devices(ctx, up, wait) {
	for (let name in up ? keys(ctx.want_up) : ctx.devices) {
		global.ubus.call('network.wireless', up ? 'up' : 'down', { device: name });
		if (global.ubus.error() != null)
			die('WIRELESS_CONTROL_FAILED');
	}
	if (wait === false) return;
	let start = clock(true)[0];
	let deadline = start + (up ? 90 : 20);
	let cac = {};
	while (clock(true)[0] <= deadline) {
		let status = global.ubus.call('network.wireless', 'status');
		if (type(status) != 'object')
			die('WIRELESS_STATUS_UNAVAILABLE');
		let ready = true;
		for (let name in up ? keys(ctx.want_up) : ctx.devices) {
			let device = status[name];
			if (device?.teardown_failed)
				die('WIRELESS_STOP_FAILED');
			if (up && device?.retry_setup_failed && !device.pending)
				die(device.activation?.error ?? 'WIRELESS_START_FAILED');
			if (up && !cac[name] && device?.activation?.phase == 'cac') {
				cac[name] = true;
				deadline = max(deadline, min(start + 700,
					clock(true)[0] + min(600, device.activation.cac_seconds || 600) + 30));
			}
			ready &&= !!device && !device.pending && (up ? !!device.up : !device.up);
		}
		if (ready) return;
		sleep(up ? 0.5 : 0.1);
	}
	die(up ? 'WIRELESS_START_TIMEOUT' : 'WIRELESS_STOP_TIMEOUT');
};

function vendor_module_order() {
	let allowed = { mt_wifi: true, mtk_hwifi: true, connac_if: true,
		mtk_pci: true, mtk_wed: true, mt7990: true, mt7991: true,
		mt7992: true, mt7993: true, mtk_warp: true, mtk_warp_proxy: true,
		debugger_wifi: true };
	let visited = {};
	let order = [];
	function visit(name) {
		if (!allowed[name]) die('WIRELESS_DRIVER_BUSY');
		if (visited[name]) return;
		visited[name] = true;
		for (let path in fs.glob(`/sys/module/${name}/holders/*`))
			visit(fs.basename(path));
		push(order, name);
	};
	visit('mt_wifi');
	return order;
};

function reload_vendor_module(ctx, recover) {
	let status = global.ubus.call('network.wireless', 'status');
	if (type(status) != 'object') die('WIRELESS_STATUS_UNAVAILABLE');
	for (let _, device in status)
		if (device.config?.type == 'mtwifi' &&
		    (device.up || device.pending || device.teardown_failed))
			die('WIRELESS_DRIVER_BUSY');
	ctx.module_order ??= vendor_module_order();
	ctx.root_changed ??= !!ctx.module_changed;
	for (let name in keys(l1dat.load_cached()?.[l1dat.IF_RINDEX] ?? {}))
		if (exists(`/sys/class/net/${name}`) &&
		    system(`ip link set dev ${shell_quote(name)} down`))
			die('WIRELESS_LINK_STOP_FAILED');
	if (!recover || ctx.root_changed)
		for (let name in ctx.module_order) {
			if (!exists(`/sys/module/${name}`)) continue;
			if (system(`/sbin/rmmod ${name}`)) die('WIRELESS_DRIVER_BUSY');
			ctx.module_changed = true;
			if (name == 'mt_wifi') ctx.root_changed = true;
		}
	for (let name in reverse([...ctx.module_order]))
		if (system(`/sbin/modprobe ${name}`)) die('WIRELESS_DRIVER_START_FAILED');
};

function with_config_lock(callback, idle) {
	let lock = idle ? rebuild_config_lock() : fs.open('/var/run/mtwifi-config.lock', 'ae', 0600);
	if (!lock || (!idle && !lock.lock('x'))) die('CONFIG_LOCK_FAILED');
	let result;
	try { result = callback(); }
	catch (e) { lock.close(); die(e); }
	lock.close();
	return result;
};

function restore_rebuild(ctx) {
	try {
		rebuild_devices(ctx, false);
		with_config_lock(() => {
			for (let file in ctx.files)
				if (!atomic_write(file.path, file.previous)) die('PROFILE_RESTORE_FAILED');
			if (ctx.module_changed) reload_vendor_module(ctx, true);
			if (!atomic_write(REBUILD_RESTORE, sprintf('%J\n', {
				source: rebuild_source(), radios: ctx.records,
				config: rebuild_inventory(ctx.records),
				want_up: ctx.want_up,
			}))) die('REBUILD_METADATA_FAILED');
			for (let path in ctx.markers) fs.unlink(path);
			rebuild_status('recovering');
			fs.unlink(REINSTALL_LOCK);
		});
		rebuild_devices(ctx, true);
		return true;
	} catch (e) { log(`wireless rebuild recovery failed: ${e}`); return false; }
};

function rebuild_run() {
	let ctx = read_json(REBUILD_TRANSACTION);
	if (exists(REBUILD_TRANSACTION) &&
	    (type(ctx) != 'object' || type(ctx.files) != 'array' || type(ctx.records) != 'object')) {
		rebuild_status('failed', 'REBUILD_STATE_INVALID', false);
		return 1;
	}
	let queued;
	let queue;
	try {
		if (ctx) {
			let recovered = restore_rebuild(ctx);
			rebuild_status('failed', 'INTERRUPTED_REBUILD', recovered);
			if (recovered) fs.unlink(REBUILD_TRANSACTION);
			return recovered ? 0 : 1;
		}
		sleep(0.2);
		queue = read_json(REBUILD_QUEUE);
		if (!queue) return 0;
		let ready = with_config_lock(() => {
			queued = readfile(REBUILD_QUEUE);
			queue = queued ? json(queued) : null;
			if (!queue) return false;
			if (queue.source != rebuild_source()) {
				fs.unlink(REBUILD_QUEUE);
				die('WIRELESS_CONFIG_CHANGED');
			}
			ctx = { devices: [], want_up: {}, records: {}, markers: [], files: [], module_changed: false };
			let status = global.ubus.call('network.wireless', 'status');
			if (type(status) != 'object') die('WIRELESS_STATUS_UNAVAILABLE');
			for (let radio, config in uci.cursor().get_all('wireless') ?? {}) {
				if (config['.type'] != 'wifi-device' || config.type != 'mtwifi') continue;
				push(ctx.devices, radio);
				let path = `/var/run/mtwifi-${config.devname ?? radio}.configured`;
				push(ctx.markers, path);
				let record = read_json(path);
				if (record?.payload && record?.profile) ctx.records[radio] = record;
				if (status[radio]?.up || status[radio]?.pending || queue.radios[radio]) {
					ctx.want_up[radio] = true;
					if (!ctx.records[radio]) die('NO_REBUILD_SNAPSHOT');
				}
			}
			if (!length(ctx.devices) || !length(keys(ctx.want_up))) die('NO_REBUILD_SNAPSHOT');
			let profiles = {};
			for (let devname in l1dat.list(l1dat.load_cached())) {
				let path = l1dat.load_cached()[l1dat.DEV_RINDEX][devname].profile_path;
				if (!path || profiles[path]) continue;
				let previous = readfile(path);
				if (previous == null) die('PROFILE_GENERATION_FAILED');
				profiles[path] = true;
				push(ctx.files, { path, previous });
			}
			if (!atomic_write(REBUILD_TRANSACTION, sprintf('%J\n', ctx)) ||
			    !atomic_write(REINSTALL_LOCK, '1')) die('REBUILD_METADATA_FAILED');
			ctx.active = true;
			return true;
		}, true);
		if (!ready) return 0;
		rebuild_status('stopping');
		rebuild_devices(ctx, false);
		with_config_lock(() => {
			if (queue.source != rebuild_source()) die('WIRELESS_CONFIG_CHANGED');
			fs.unlink(REINSTALL_LOCK);
			for (let _, record in queue.radios) {
				let plan = cfg.prepare_dat(record.devname, record.profile);
				if (!plan.ok || !cfg.commit_dat(plan)) die('PROFILE_WRITE_FAILED');
			}
			if (!atomic_write(REINSTALL_LOCK, '1')) die('REBUILD_METADATA_FAILED');
			rebuild_status('reloading');
			ctx.module_order = vendor_module_order();
			/* Persist the recovery requirement before entering module teardown. */
			if (!atomic_write(REBUILD_TRANSACTION, sprintf('%J\n', {
				...ctx, module_changed: true, root_changed: true,
			})))
				die('REBUILD_METADATA_FAILED');
			reload_vendor_module(ctx);
			if (queue.source != rebuild_source()) die('WIRELESS_CONFIG_CHANGED');
			for (let path in ctx.markers) fs.unlink(path);
			fs.unlink(REBUILD_RESTORE);
			fs.unlink(REBUILD_QUEUE);
			rebuild_status('starting');
			fs.unlink(REINSTALL_LOCK);
		});
		rebuild_devices(ctx, true);
		if (queue.source != rebuild_source()) die('WIRELESS_CONFIG_CHANGED');
		fs.unlink(REBUILD_TRANSACTION);
		rebuild_status('ready');
		return 0;
	} catch (e) {
		let error = e.message ?? '' + e;
		with_config_lock(() => {
			if (queued != null && readfile(REBUILD_QUEUE) == queued)
				fs.unlink(REBUILD_QUEUE);
		});
		let recovered = ctx?.active ? restore_rebuild(ctx) : true;
		if (recovered) fs.unlink(REBUILD_TRANSACTION);
		rebuild_status('failed', error, recovered);
		return 1;
	}
};

function prepare_retry() {
	if (exists(REBUILD_TRANSACTION) && rebuild_run())
		die('WIRELESS_CONFIG_RESTORE_FAILED');
	let restored = read_json(REBUILD_RESTORE);
	let status = global.ubus.call('network.wireless', 'status');
	if (type(status) != 'object') die('WIRELESS_STATUS_UNAVAILABLE');
	let ctx = { devices: [], want_up: {} };
	for (let radio, config in uci.cursor().get_all('wireless') ?? {}) {
		if (config['.type'] != 'wifi-device' || config.type != 'mtwifi') continue;
		push(ctx.devices, radio);
		if (!+config.disabled && (restored?.want_up?.[radio] || status[radio]?.autostart ||
		    status[radio]?.up || status[radio]?.pending))
			ctx.want_up[radio] = true;
	}
	rebuild_devices(ctx, false);
	with_config_lock(() => {
		fs.unlink(REBUILD_RESTORE);
		fs.unlink(REBUILD_QUEUE);
		fs.unlink(REBUILD_STATUS);
	});
	return ctx;
};

function rebuild(retry) {
	let owner = fs.open('/var/run/mtwifi-rebuild.lock', 'ae', 0600);
	if (!owner) {
		rebuild_status('failed', 'REBUILD_METADATA_FAILED', false);
		return 1;
	}
	if (!owner.lock('xn')) { owner.close(); return 0; }
	let result = 0;
	let restart;
	try {
		if (retry) restart = prepare_retry();
		else result = rebuild_run();
	} catch (e) {
		log(`wireless rebuild failed: ${e}`);
		rebuild_status('failed', e.message ?? '' + e, false);
		result = 1;
	}
	fs.unlink(REINSTALL_LOCK);
	owner.close();
	if (restart) {
		try { rebuild_devices(restart, true, false); }
		catch (e) {
			rebuild_status('failed', 'WIRELESS_CONTROL_FAILED', false);
			result = 1;
		}
	}
	return result;
};

let setup_transaction, config_lock;

function try_rollback(step, callback) {
	try { return callback() ?? true; }
	catch (e) { log(`rollback ${step} failed: ${e}`); return false; }
};

function rollback_setup(recover) {
	let tx = setup_transaction;
	if (!tx)
		return true;
	setup_transaction = null;
	/* Do not reattach an old BSS while the new vendor profile is still live. */
	let stopped_sta = try_rollback('STA stop', () => mt_supplicant.stop(tx.sta));
	let stopped_ap = try_rollback('AP stop', () => mt_hostapd.stop(tx.ap));
	let metadata = !tx.metadata || try_rollback('metadata', () => rollback_files(tx.metadata));
	let restored = !tx.dat || try_rollback('vendor profiles', () => cfg.rollback_dat(tx.dat));
	let restart = recover != false && restored && stopped_sta && stopped_ap;
	let ap_restored = try_rollback('AP files', () => mt_hostapd.rollback(tx.ap, restart));
	let sta_restored = try_rollback('STA files', () => mt_supplicant.rollback(tx.sta, restart));
	let ok = restored && stopped_sta && stopped_ap && metadata && ap_restored && sta_restored;
	if (ok && tx.journal) fs.unlink(tx.journal);
	if (!ok)
		log('configuration rollback failed; keeping failed setup down');
	return ok;
};

function restore_runtime(tx, reason) {
	let previous = tx.previous;
	if (tx.reported_vifs || !previous?.profile_applied || !previous.payload)
		return false;
	let ifaces = previous.profile?.interfaces ?? {};
	if (!length(keys(ifaces))) return false;
	let ap = global.ubus.call('hostapd', 'get_radio_status', { iface: tx.identity.phy });
	for (let _, entry in ifaces) {
		let config = entry.config;
		if (config?.disabled) continue;
		if (config.mode == 'ap' && !config.start_disabled &&
		    (ap?.status != 'ENABLED' || !ap.bss?.[config.ifname]?.beacon_ready))
			return false;
		if (config.mode == 'sta' && !length(global.ubus.list('wpa_supplicant.' + config.ifname)))
			return false;
	}
	netifd.restore_config(previous.payload);
	for (let id, entry in ifaces)
		if (entry.config?.ifname) netifd.set_vif(id, entry.config.ifname);
	netifd.set_data({ ...tx.identity, activation: {
		phase: 'restored', freq: ap?.freq, channel: ap?.channel, error: reason,
	} });
	log(`restored last active configuration for ${tx.identity.devname} after ${reason}`);
	return netifd.set_up();
};

function fail_setup(reason) {
	let tx = setup_transaction;
	let data = tx?.identity;
	if (rollback_setup(reason != 'ACTIVATION_CANCELED') && tx && reason != 'ACTIVATION_CANCELED') {
		let recovered = try_rollback('runtime', () => restore_runtime(tx, reason));
		if (recovered) return 0;
	}
	if (data)
		netifd.set_data({ ...data, activation: {
			phase: reason == 'ACTIVATION_CANCELED' ? 'canceled' : 'failed', error: reason,
		} });
	if (reason == 'ACTIVATION_CANCELED')
		return 1;
	netifd.setup_failed(reason);
	return 1;
};

function setup() {
	let payload = json(ARGV[3]);

	if (type(payload) != 'object') {
		log('invalid payload');
		netifd.set_retry(false);
		return 1;
	}
	if (exists(REBUILD_TRANSACTION)) {
		let status = read_json(REBUILD_STATUS);
		if (exists(REINSTALL_LOCK) || !(status?.phase in [ 'starting', 'recovering' ])) {
			let probe = fs.open('/var/run/mtwifi-rebuild.lock', 'ae', 0600);
			if (probe?.lock('xn')) {
				probe.close();
				if (status?.phase != 'failed') spawn_rebuild();
			}
			netifd.setup_failed(status?.phase == 'failed' ? 'DRIVER_REBUILD_FAILED' : 'DRIVER_REBUILD_PENDING');
			return 1;
		}
	}
	let restored = read_json(REBUILD_RESTORE);
	if (restored?.source == rebuild_source() && restored.radios?.[ARGV[2]]?.payload)
		payload = json(sprintf('%J', restored.radios[ARGV[2]].payload));
	else {
		restored = null;
		fs.unlink(REBUILD_RESTORE);
	}
	let original = json(sprintf('%J', payload));

	let l1 = l1dat.load_cached();

	if (!l1) {
		log(`no L1 profile (${l1dat.L1_DAT_PATH})`);
		netifd.setup_failed('NO_L1_PROFILE');
		return 1;
	}

	let devname = resolve_devname(l1, payload, ARGV[2]);
	let dev = devname ? l1[l1dat.DEV_RINDEX][devname] : null;

	if (!dev) {
		log(`unknown device ${ARGV[2]} (devname ${devname})`);
		netifd.setup_failed('UNKNOWN_DEVICE');
		return 1;
	}
	for (let name, config in uci.cursor().get_all('wireless') ?? {})
		if (name != ARGV[2] && config['.type'] == 'wifi-device' &&
		    config.type == 'mtwifi' && !+config.disabled && (config.devname ?? name) == devname)
			die('PHY_PROFILE_MISMATCH');
	let marker = `/var/run/mtwifi-${devname}.configured`;
	if (exists(marker + '.pending')) {
		netifd.setup_failed('ACTIVATION_RECOVERY_PENDING');
		return 1;
	}
	let previous = read_json(marker);
	let profile_applied = previous?.profile_applied ?? (length(keys(previous?.profile?.interfaces ?? {})) > 0);
	if (!length(keys(payload.interfaces ?? {}))) {
		let phy = phy_of_ifname(dev.main_ifname) ?? payload.data?.phy;
		if (!mt_supplicant.teardown(dev.apcli_ifname)) die('SUPPLICANT_STOP_FAILED');
		if (phy && !mt_hostapd.teardown(phy, payload.config?.radio)) die('HOSTAPD_STOP_FAILED');
		if (restored) netifd.restore_config(original);
		if (!ifname.remove_wps_map(dev, IFACE_WPS_FILE) ||
		    !atomic_write(marker, sprintf('%J\n', {
			    radio: ARGV[2], devname, payload: original, profile: payload, profile_applied,
		    }))) {
			netifd.setup_failed('METADATA_WRITE_FAILED');
			return 1;
		}
		netifd.set_data({ phy, devname, radio: payload.config?.radio });
		netifd.set_up();
		return 0;
	}

	let phy = phy_of_ifname(dev.main_ifname);
	let previous_radio = previous?.profile?.config?.radio ?? payload.config?.radio;
	setup_transaction = { previous, identity: {
		phy, devname, radio: previous_radio, suffix: mt_hostapd.suffix_of(previous_radio),
	} };

	/* Validate before creating files, changing interfaces or sending commands. */
	normalize_legacy_device(payload.config, dev);
	let country = payload.config?.country;
	sanitize_device(payload.config);
	validate_device(payload.config);
	payload.config.country ??= country;
	ifname.assign(payload, dev);
	validate_profile(payload, restored?.config);
	validate_ifaces(payload);

	/* 5. phy / 后缀 */
	phy = resolve_phy(payload.config, dev);

	if (!phy) {
		log(`no phy for ${devname}`);
		print('NO_PHY\n');
		return 1;
	}

	let suffix = mt_hostapd.suffix_of(payload.config.radio);
	let has_ap = ifname.has_mode(payload, 'ap');
	let has_sta = ifname.has_mode(payload, 'sta');
	let previous_ap = ifname.has_mode(previous?.profile ?? {}, 'ap');
	let previous_sta = ifname.has_mode(previous?.profile ?? {}, 'sta');

	payload.phy = phy;
	payload.config.phy = phy;
	payload.phy_suffix = suffix;
	payload.vif_phy_suffix = suffix;
	let caps = validate_capabilities(payload);

	if (!payload.config.ifname_prefix)
		payload.ifname_prefix = `${phy}${suffix}-`;

	if ((has_ap || previous_ap) && !mt_hostapd.wait_ready()) {
		/* Service startup is transient; preserve netifd's bounded retry budget. */
		log('hostapd is not ready; keeping netifd setup retries');
		print('HOSTAPD_UNAVAILABLE\n');
		return 1;
	}
	if (has_sta && !mt_supplicant.wait_ready()) {
		log('wpa_supplicant is not ready; keeping netifd setup retries');
		print('SUPPLICANT_UNAVAILABLE\n');
		return 1;
	}
	let record = { radio: ARGV[2], devname, payload: original,
		profile: json(sprintf('%J', payload)), profile_applied: true,
		activation_id: join('-', clock(true)) };
	let dat_plan = cfg.prepare_dat(devname, payload, caps);
	if (!dat_plan.ok) return fail_setup('PROFILE_GENERATION_FAILED');
	if (dat_plan.reinstall && (profile_applied || (exists(marker) && (!previous?.payload || !previous?.profile)))) {
		if (!previous?.payload || !previous?.profile || restored ||
		    !exists('/sys/module/mt_wifi/refcnt')) {
			netifd.setup_failed('DRIVER_RESTART_REQUIRED');
			return 1;
		}
		netifd.setup_failed(queue_rebuild(record) ? 'DRIVER_REBUILD_PENDING' : 'DRIVER_REBUILD_FAILED');
		return 1;
	}
	let ap_plan = has_ap || previous_ap ? mt_hostapd.prepare(payload, caps) : null;
	if (ap_plan && !ap_plan.ok) return fail_setup('HOSTAPD_CONFIG_FAILED');
	if (ap_plan) {
		ap_plan.previous_registrars = previous?.registrars ?? [];
		record.registrars = ap_plan.registrars;
	}
	let sta_plan = has_sta ? mt_supplicant.prepare(payload) : null;
	if (sta_plan && !sta_plan.ok) return fail_setup('SUPPLICANT_CONFIG_FAILED');
	let identity = { phy, radio: payload.config.radio, devname, suffix };
	setup_transaction = {
		dat: dat_plan, ap: ap_plan, sta: sta_plan,
		identity, previous,
		metadata: { files: map([ IFACE_WPS_FILE, marker ], (path) => ({
			path, previous: readfile(path), previous_owner: fs.stat(path),
		})), committed: [] },
	};
	let last_activation;
	let report_activation = (phase, state, error) => {
		let activation = { phase, freq: state?.freq, channel: state?.channel,
			cac_seconds: phase == 'cac' ? state?.cac_seconds : null, error };
		let signature = sprintf('%J', activation);
		if (signature == last_activation) return;
		last_activation = signature;
		log(`${devname}: activation ${phase}${state?.freq ? ' at ' + state.freq + ' MHz' : ''}${error ? ' (' + error + ')' : ''}`);
		netifd.set_data({ ...identity, activation });
	};
	if (restored) netifd.restore_config(original);
	if (!cfg.commit_dat(dat_plan))
		return fail_setup('PROFILE_WRITE_FAILED');
	report_activation('configuring');
	if (ap_plan && !mt_hostapd.activate(ap_plan))
		return fail_setup('HOSTAPD_START_FAILED');
	if (ap_plan && length(ap_plan.ifnames)) {
		/* Keep the rollback snapshot if the deferred handler is killed. */
		setup_transaction.journal = marker + '.pending';
		setup_transaction.activation_id = record.activation_id;
		if (!atomic_write(setup_transaction.journal, sprintf('%J\n', setup_transaction)))
			return fail_setup('METADATA_WRITE_FAILED');
		if (!netifd.defer_setup())
			return fail_setup('HOSTAPD_ACTIVATION_UNAVAILABLE');
		report_activation('configured');
		config_lock.close();
		config_lock = null;
		let failure, exception;
		try {
			failure = mt_hostapd.activation(ap_plan, report_activation, (bus) => {
				let status = bus.call('network.wireless', 'status')?.[global.radio];
				return status && (!status.pending || !status.autostart || status.activation_canceled);
			});
		} catch (e) {
			exception = e;
		}
		config_lock = fs.open('/var/run/mtwifi-config.lock', 'ae', 0600);
		if (!config_lock || !config_lock.lock('x')) die('CONFIG_LOCK_FAILED');
		if (exception) die(exception);
		if (failure)
			return fail_setup(failure);
	}
	if (sta_plan && !mt_supplicant.activate(sta_plan))
		return fail_setup('SUPPLICANT_START_FAILED');
	if (!has_sta && previous_sta && !mt_supplicant.teardown(dev.apcli_ifname))
		return fail_setup('SUPPLICANT_STOP_FAILED');
	cfg.driver_up(devname, payload);
	/* Other radios may have updated the shared map while this radio waited. */
	let wps_snapshot = setup_transaction.metadata.files[0];
	wps_snapshot.previous = readfile(IFACE_WPS_FILE);
	wps_snapshot.previous_owner = fs.stat(IFACE_WPS_FILE);
	setup_transaction.metadata.committed = setup_transaction.metadata.files;
	if (!ifname.write_wps_map(payload, dev, IFACE_WPS_FILE) ||
	    !atomic_write(marker, sprintf('%J\n', record)))
		return fail_setup('METADATA_WRITE_FAILED');
	if (!mt_hostapd.complete(ap_plan))
		return fail_setup('WPS_REGISTRAR_START_FAILED');
	setup_transaction.reported_vifs = true;
	for (let k in vif_keys(payload))
		netifd.set_vif(k, payload.interfaces[k].config.ifname);
	if (!has_ap)
		report_activation('station_configured');
	if (!netifd.set_up())
		return fail_setup('ACTIVATION_CANCELED');
	if (setup_transaction.journal) fs.unlink(setup_transaction.journal);
	setup_transaction = null;

	return 0;
};

/* ------------------------------------------------------------------ */
/* teardown                                                            */
/* ------------------------------------------------------------------ */

function teardown() {
	let payload = json(ARGV[3]) ?? {};
	let l1 = l1dat.load_cached();

	if (ARGV[2] == '#mlo')
		return 0;

	let devname = payload.data?.devname ?? resolve_devname(l1, payload, ARGV[2]);
	let dev = (l1 && devname) ? l1[l1dat.DEV_RINDEX][devname] : null;
	let phy = payload.data?.phy ?? phy_of_ifname(dev?.main_ifname);
	let radio = payload.data?.radio ?? payload.config?.radio;

	log(`teardown ${ARGV[2]} (devname ${devname}, phy ${phy})`);

	if (dev) {
		let marker = `/var/run/mtwifi-${devname}.configured`;
		let path = marker + '.pending';
		if (exists(path)) {
			let interrupted = read_json(path);
			if (interrupted?.identity?.devname != devname || interrupted.journal != path)
				die('ACTIVATION_SNAPSHOT_INVALID');
			if (read_json(marker)?.activation_id != interrupted.activation_id) {
				setup_transaction = interrupted;
				if (!rollback_setup(false)) die('ACTIVATION_RESTORE_FAILED');
			}
			fs.unlink(path);
		}
	}

	if (!mt_supplicant.teardown(dev?.apcli_ifname)) die('SUPPLICANT_STOP_FAILED');

	if (phy && !mt_hostapd.teardown(phy, radio)) die('HOSTAPD_STOP_FAILED');

	cfg.driver_down(devname, payload);

	/* 只清掉本 radio 的 WPS 映射，保留其它 radio */
	ifname.remove_wps_map(dev, IFACE_WPS_FILE);

	return 0;
};

/* ------------------------------------------------------------------ */

let ret = 1;
try {
	if (ARGV[1] == 'setup' || ARGV[1] == 'teardown') {
		config_lock = fs.open('/var/run/mtwifi-config.lock', 'ae', 0600);
		if (!config_lock || !config_lock.lock('x'))
			die('CONFIG_LOCK_FAILED');
	}

	switch (ARGV[1]) {
	case 'dump': ret = dump_options(); break;
	case 'setup': ret = setup(); break;
	case 'teardown': ret = teardown(); break;
	case 'rebuild': ret = rebuild(); break;
	case 'retry': ret = rebuild(true); break;
	}
} catch (e) {
	log(`wireless operation failed: ${e}`);
	if (ARGV[1] == 'setup') {
		let reason = match(e.message ?? '', /^(AP_VLAN_NOT_SUPPORTED|PHY_PROFILE_MISMATCH|ACS_[A-Z_]+|SIX_GHZ_POWER_TYPE_NOT_SUPPORTED|INVALID_MWDS_MODE|INVALID_MAC_ACL|MAC_ACL_TOO_LARGE)$/);
		try { ret = fail_setup(reason ? reason[0] : 'INVALID_CONFIG'); }
		catch (re) { log(`rollback failed: ${re}`); }
	}
}
if (config_lock) config_lock.close();
exit(ret);

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
import { find_phy } from 'wifi.utils';

import * as l1dat from 'mtwifi.l1dat';
import * as cfg from 'mtwifi.cfg';
import { validate_capabilities } from 'mtwifi.caps';
import { validate_profile } from 'mtwifi.validate';
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
		[ 'whnat', TYPE.boolean ],
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
		[ 'map_mode', TYPE.number ],
		[ 'obss_interval', TYPE.number ],
		[ 'eht_bw320_offset', TYPE.number ],
	],
	iface: [
		[ 'mldgroup', TYPE.number ],
		[ 'ieee80211w', TYPE.number ],
		[ 'mwds', TYPE.boolean ],
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
	/* PHY numbers can change after unloading; the L1 netdevice remains authoritative. */
	if (expected) {
		if (config.path || config.macaddr) {
			let bound = find_phy({ ...config, phy: expected }, true);
			if (bound && bound != expected) die('PHY_PROFILE_MISMATCH');
		}
		return expected;
	}
	let phy = find_phy(config, true);
	if (!phy)
		log(`cannot resolve phy for ${dev?.main_ifname ?? 'unknown'}`);
	return phy;
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
	for (let attempt = 0; attempt < (up ? 180 : 200); attempt++) {
		let status = global.ubus.call('network.wireless', 'status');
		if (type(status) != 'object')
			die('WIRELESS_STATUS_UNAVAILABLE');
		let ready = true;
		for (let name in up ? keys(ctx.want_up) : ctx.devices) {
			let device = status[name];
			ready &&= !!device && !device.pending && (up ? !!device.up : !device.up);
		}
		if (ready) return;
		sleep(up ? 0.5 : 0.1);
	}
	die(up ? 'WIRELESS_START_TIMEOUT' : 'WIRELESS_STOP_TIMEOUT');
};

function reload_vendor_module(ctx) {
	for (let name in keys(l1dat.load_cached()?.[l1dat.IF_RINDEX] ?? {}))
		if (exists(`/sys/class/net/${name}`) &&
		    system(`ip link set dev ${shell_quote(name)} down`))
			die('WIRELESS_LINK_STOP_FAILED');
	if (exists('/sys/module/mt_wifi')) {
		if (length(fs.glob('/sys/module/mt_wifi/holders/*')) || system('/sbin/rmmod mt_wifi'))
			die('WIRELESS_DRIVER_BUSY');
	}
	ctx.module_changed = true;
	if (system('/sbin/modprobe mt_wifi'))
		die('WIRELESS_DRIVER_START_FAILED');
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
			if (ctx.module_changed) reload_vendor_module(ctx);
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
			/* Persist the recovery requirement before entering module teardown. */
			if (!atomic_write(REBUILD_TRANSACTION, sprintf('%J\n', { ...ctx, module_changed: true })))
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

let setup_transaction;

function try_rollback(step, callback) {
	try { return callback() ?? true; }
	catch (e) { log(`rollback ${step} failed: ${e}`); return false; }
};

function rollback_setup() {
	let tx = setup_transaction;
	if (!tx)
		return;
	setup_transaction = null;
	/* Do not reattach an old BSS while the new vendor profile is still live. */
	let stopped_sta = try_rollback('STA stop', () => mt_supplicant.stop(tx.sta));
	let stopped_ap = try_rollback('AP stop', () => mt_hostapd.stop(tx.ap));
	let metadata = try_rollback('metadata', () => rollback_files(tx.metadata));
	let restored = try_rollback('vendor profiles', () => cfg.rollback_dat(tx.dat));
	let restart = restored && stopped_sta && stopped_ap;
	let ap_restored = try_rollback('AP files', () => mt_hostapd.rollback(tx.ap, restart));
	let sta_restored = try_rollback('STA files', () => mt_supplicant.rollback(tx.sta, restart));
	if (!restart || !metadata || !ap_restored || !sta_restored)
		log('configuration rollback failed; keeping failed setup down');
};

function fail_setup(reason) {
	rollback_setup();
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
	if (!length(keys(payload.interfaces ?? {}))) {
		let phy = phy_of_ifname(dev.main_ifname) ?? payload.data?.phy;
		mt_supplicant.teardown(dev.apcli_ifname);
		if (phy) mt_hostapd.teardown(phy, payload.config?.radio);
		if (restored) netifd.restore_config(original);
		if (!ifname.remove_wps_map(dev, IFACE_WPS_FILE) ||
		    !atomic_write(`/var/run/mtwifi-${devname}.configured`, sprintf('%J\n', {
			    radio: ARGV[2], devname, payload: original, profile: payload,
		    }))) {
			netifd.setup_failed('METADATA_WRITE_FAILED');
			return 1;
		}
		netifd.set_data({ phy, devname, radio: payload.config?.radio });
		netifd.set_up();
		return 0;
	}

	/* Validate before creating files, changing interfaces or sending commands. */
	let country = payload.config?.country;
	sanitize_device(payload.config);
	validate_device(payload.config);
	payload.config.country ??= country;
	ifname.assign(payload, dev);
	validate_profile(payload, restored?.config);
	validate_ifaces(payload);

	/* 5. phy / 后缀 */
	let phy = resolve_phy(payload.config, dev);

	if (!phy) {
		log(`no phy for ${devname}`);
		netifd.setup_failed('NO_PHY');
		return 1;
	}

	let suffix = mt_hostapd.suffix_of(payload.config.radio);
	let has_ap = ifname.has_mode(payload, 'ap');
	let has_sta = ifname.has_mode(payload, 'sta');

	payload.phy = phy;
	payload.config.phy = phy;
	payload.phy_suffix = suffix;
	payload.vif_phy_suffix = suffix;
	validate_capabilities(payload);

	/* MTK APCLI uses the AP's configured channel; do not silently strand an AP. */
	payload.ap_start_disabled = false;
	for_each_vif(payload, 'ap', (k, v) => {
		payload.ap_start_disabled ||= !!v.config.start_disabled;
	});

	if (!payload.config.ifname_prefix)
		payload.ifname_prefix = `${phy}${suffix}-`;

	if (has_ap && !mt_hostapd.wait_ready()) {
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
		profile: json(sprintf('%J', payload)) };
	let dat_plan = cfg.prepare_dat(devname, payload);
	if (!dat_plan.ok) {
		netifd.setup_failed('PROFILE_GENERATION_FAILED');
		return 1;
	}
	let marker = `/var/run/mtwifi-${devname}.configured`;
	if (dat_plan.reinstall && exists(marker)) {
		let previous = read_json(marker);
		if (!previous?.payload || !previous?.profile || restored ||
		    !exists('/sys/module/mt_wifi/refcnt')) {
			netifd.setup_failed('DRIVER_RESTART_REQUIRED');
			return 1;
		}
		netifd.setup_failed(queue_rebuild(record) ? 'DRIVER_REBUILD_PENDING' : 'DRIVER_REBUILD_FAILED');
		return 1;
	}
	let ap_plan = has_ap ? mt_hostapd.prepare(payload) : null;
	if (ap_plan && !ap_plan.ok) {
		netifd.setup_failed('HOSTAPD_CONFIG_FAILED');
		return 1;
	}
	let sta_plan = has_sta ? mt_supplicant.prepare(payload) : null;
	if (sta_plan && !sta_plan.ok) {
		netifd.setup_failed('SUPPLICANT_CONFIG_FAILED');
		return 1;
	}
	setup_transaction = {
		dat: dat_plan, ap: ap_plan, sta: sta_plan,
		metadata: { files: map([ IFACE_WPS_FILE, marker ], (path) => ({
			path, previous: readfile(path), previous_owner: fs.stat(path),
		})), committed: [] },
	};
	if (restored) netifd.restore_config(original);
	if (!cfg.commit_dat(dat_plan))
		return fail_setup('PROFILE_WRITE_FAILED');
	if (ap_plan && !mt_hostapd.activate(ap_plan))
		return fail_setup('HOSTAPD_START_FAILED');
	if (sta_plan && !mt_supplicant.activate(sta_plan))
		return fail_setup('SUPPLICANT_START_FAILED');
	cfg.driver_up(devname, payload);
	mt_hostapd.complete(ap_plan);
	for (let k in vif_keys(payload))
		netifd.set_vif(k, payload.interfaces[k].config.ifname);
	setup_transaction.metadata.committed = setup_transaction.metadata.files;
	if (!ifname.write_wps_map(payload, dev, IFACE_WPS_FILE) ||
	    !atomic_write(marker, sprintf('%J\n', record)))
		return fail_setup('METADATA_WRITE_FAILED');
	netifd.set_data({ phy, radio: payload.config.radio, devname, suffix });
	netifd.set_up();
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

	mt_supplicant.teardown(dev?.apcli_ifname);

	if (phy)
		mt_hostapd.teardown(phy, radio);

	cfg.driver_down(devname, payload);

	/* 只清掉本 radio 的 WPS 映射，保留其它 radio */
	ifname.remove_wps_map(dev, IFACE_WPS_FILE);

	return 0;
};

/* ------------------------------------------------------------------ */

let ret = 1;
let config_lock;
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
		try { rollback_setup(); } catch (re) { log(`rollback failed: ${re}`); }
		netifd.setup_failed(e.message == 'AP_VLAN_NOT_SUPPORTED' ? e.message : 'INVALID_CONFIG');
	}
}
if (config_lock) config_lock.close();
exit(ret);

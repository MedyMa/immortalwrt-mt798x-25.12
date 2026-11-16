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
import { validate_profile } from 'mtwifi.validate';
import * as ifname from 'mtwifi.ifname';
import * as mt_hostapd from 'mtwifi.hostapd';
import * as mt_supplicant from 'mtwifi.supplicant';
import { log, trim, exists, shell_quote, sleep, readfile, atomic_write, rollback_files } from 'mtwifi.common';

global.radio = ARGV[2];

const REINSTALL_LOCK = '/tmp/mtwifi_reloading.lock';
const IFACE_WPS_FILE = '/var/run/mtwifi-iface-wps';
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
		[ 'dfs', TYPE.boolean ],
		[ 'zw_dfs', TYPE.boolean ],
		[ 'vendor_vht', TYPE.boolean ],
		[ 'vht_1024', TYPE.boolean ],
		[ 'he_ldpc', TYPE.boolean ],
		[ 'map_mode', TYPE.number ],
		[ 'obss_interval', TYPE.number ],
		[ 'eht_bw320_offset', TYPE.number ],
	],
	iface: [
		[ 'mldgroup', TYPE.number ],
		[ 'mwds', TYPE.boolean ],
		[ 'disable_eht', TYPE.boolean ],
		[ 'amsdu', TYPE.boolean ],
		[ 'autoba', TYPE.boolean ],
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

	for (let opt in extras) {
		let key = opt[0];

		if (config[key] != null) {
			saved[key] = opt[1] == TYPE.boolean ? !!+config[key] :
				opt[1] == TYPE.number ? +config[key] : config[key];
			if (opt[1] == TYPE.number && !(saved[key] >= -127 && saved[key] <= 65535))
				die('INVALID_VENDOR_OPTION');
			delete config[key];
		}
	}

	validate(kind, config);

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
	let phy = find_phy(config, true);

	let expected = phy_of_ifname(dev?.main_ifname);
	if (phy && expected && phy != expected)
		die('PHY_PROFILE_MISMATCH');
	if (phy)
		return phy;

	phy = expected;

	if (!phy) {
		log(`cannot resolve phy for ${dev?.main_ifname ?? 'unknown'}`);
		return null;
	}

	return phy;
};

/* ------------------------------------------------------------------ */
/* setup                                                               */
/* ------------------------------------------------------------------ */

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

	/* Validate before creating files, changing interfaces or sending commands. */
	let country = payload.config?.country;
	sanitize_device(payload.config);
	validate_device(payload.config);
	payload.config.country ??= country;
	ifname.assign(payload, dev);
	validate_profile(payload);
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
	payload.phy_suffix = suffix;
	payload.vif_phy_suffix = suffix;

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
	let dat_plan = cfg.prepare_dat(devname, payload);
	if (!dat_plan.ok) {
		netifd.setup_failed('PROFILE_GENERATION_FAILED');
		return 1;
	}
	let marker = `/var/run/mtwifi-${devname}.configured`;
	if (dat_plan.reinstall && exists(marker)) {
		log('structural profile change requires a device restart; keeping the previous profile');
		netifd.setup_failed('DRIVER_RESTART_REQUIRED');
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
	if (!ifname.write_wps_map(payload, dev, IFACE_WPS_FILE) || !atomic_write(marker, '1'))
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
	}
} catch (e) {
	log(`wireless operation failed: ${e}`);
	if (ARGV[1] == 'setup') {
		try { rollback_setup(); } catch (re) { log(`rollback failed: ${re}`); }
		netifd.setup_failed('INVALID_CONFIG');
	}
}
if (config_lock) config_lock.close();
exit(ret);

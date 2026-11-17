'use strict';

// SPDX-License-Identifier: GPL-2.0
/*
 * mtwifi ucode support - /etc/wireless profile (.dat) generator
 *
 * Copyright (C) 2023 hanwckf <hanwckf@vip.qq.com>
 * Copyright (C) 2025-2026 nanchuci <nanchuci023@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * Functional enhancements and DOT11_EHT_BE support Modify by Nanchuci and padavanonly.
 *
 * This file is a ucode port of
 *   package/mtk/applications/mtwifi-cfg/files/mtwifi-cfg/mtwifi_cfg
 *
 * Differences to the Lua original (all of them are listed in the port report):
 *   - the whole netifd handler flow (arg parsing, cjson.decode() of the JSON
 *     payload, iface_wps file handling, rmmod/modprobe and the "/sbin/wifi up"
 *     recursion) stays in the handler; this module only exports the pieces the
 *     handler needs: get_dev(), write_dat(), driver_up(), driver_down(),
 *     reinstall() and iface_wps_map().
 *   - "v.mtwifi_ifname" (removed concept) is replaced by "v.config.ifname".
 *   - ucode has no multiple return values and no nil; Lua truthiness (0 and ""
 *     are true!) is emulated through truthy()/lua_or().
 */

import * as uci from 'uci';
import {
	log, log_syslog, atomic_write, trim, rtrim, exists, readfile, writefile, glob,
	read_pipe, shell_quote, sleep, log2file, dump
} from 'mtwifi.common';
import * as dat from 'mtwifi.dat';
import * as l1dat from 'mtwifi.l1dat';
import defs from 'mtwifi.defs';

const REINSTALL_LOCK = '/tmp/mtwifi_reloading.lock';
const IFACE_WPS_FILE = '/var/run/mtwifi-iface-wps';

/* ============================================================
 * Lua 语义兼容助手
 * ============================================================ */

/*
 * Lua 的真值判断：只有 nil 与 false 为假，0、""、空表都是真值。
 * ucode 里 0、""、NaN 也是假，所以凡是从 Lua 的 `if x then`、
 * `x and 1 or 0`、`not x` 直接搬过来的判断都统一走 truthy()。
 */
function truthy(v) {
	if (v == null)
		return false;

	if (type(v) == 'bool')
		return v;

	return true;
};

/* Lua 的 `a or b`：注意 0 / "" 在 Lua 里是真值 */
function lua_or(a, b) {
	return truthy(a) ? a : b;
};

/* Lua 的 `tonumber(x) or def`（NaN 视为转换失败） */
function num_or(v, def) {
	if (v == null)
		return def;

	let n = +v;

	/* NaN 既不 >= 0 也不 < 0 */
	if (!(n >= 0) && !(n < 0))
		return def;

	return n;
};

/* Lua 的 tostring()，null 记作 "nil"（diff_cfg 的比较语义依赖它） */
function tostr(v) {
	return v == null ? 'nil' : '' + v;
};

/* Lua 的 `x and x ~= ""` */
function has_text(x) {
	return truthy(x) && tostr(x) != '';
};

/* 原始 Lua 从 JSON 的 cfg.device 取设备名，新的 handler 也会把 devname
 * 作为第一个参数传进来；两者都支持 */
function payload_device(devname, payload) {
	return devname ?? payload?.device ?? null;
};

/* ============================================================
 * dev 查找
 * ============================================================ */

/*
 * 等价于 Lua 的 l1dat.devname_ridx[devname]；第一个参数是 l1dat 模块
 * load()/load_cached() 返回的 devs 表。找不到时返回 null（原 Lua 直接
 * 索引 nil 会崩，调用方必须判空）。
 */
export function get_dev(devs, devname) {
	if (devs == null || devname == null)
		return null;

	return devs[l1dat.DEV_RINDEX]?.[devname] ?? null;
};

/* ============================================================
 * diff_cfg：{ <key>: [ <旧值>, <新值> ] }
 * ============================================================ */
function diff_cfg(cfg1, cfg2) {
	let diff = {};

	for (let k, v in cfg1) {
		if (tostr(cfg2[k]) != tostr(v))
			diff[k] = [ lua_or(cfg1[k], ''), lua_or(cfg2[k], '') ];
	}

	for (let k, v in cfg2) {
		if (tostr(v) != tostr(cfg1[k]))
			diff[k] = [ lua_or(cfg1[k], ''), lua_or(cfg2[k], '') ];
	}

	return diff;
};

/* ============================================================
 * DBDC / cfg80211
 * ============================================================ */

/*
 * 原 Lua 的 gsub("WHNAT=[0-9]+", ...) 会替换所有匹配。
 * 这里不用 /g 正则标志（对 ucode 版本不够确定），
 * 直接按字面量查找 + 手工跳过旧数字，语义与 gsub 一致。
 */
function replace_whnat(content, whnat) {
	let out = '';
	let rest = content;

	for (;;) {
		let pos = index(rest, 'WHNAT=');

		if (pos < 0)
			break;

		out += substr(rest, 0, pos) + `WHNAT=${whnat}`;
		rest = substr(rest, pos + 6);

		let i = 0;
		while (i < length(rest)) {
			let c = substr(rest, i, 1);

			if (c < '0' || c > '9')
				break;

			i++;
		}

		rest = substr(rest, i);
	}

	return out + rest;
};

/*
 * whnat 是全局设置：LuCI 可能把它放在任意一个 wifi-device 上。
 * 遍历 UCI 找到第一个配了 whnat 的 wifi-device，返回值；都没有则返回 null。
 */
function read_whnat_global() {
	let sections = uci.cursor().get_all('wireless') ?? {};

	for (let name, sec in sections)
		if (sec['.type'] == 'wifi-device' && sec.whnat != null)
			return sec.whnat;

	return null;
};

function is_dbdc_inited(ifname) {
	if (ifname == null)
		return false;

	let mac = trim(read_pipe(`cat /sys/class/net/${ifname}/address 2>/dev/null`));

	return mac != null && length(mac) > 0 && mac != '00:00:00:00:00:00';
};

function is_cfg80211_enabled(ifname) {
	return ifname != null && exists(`/sys/class/net/${ifname}/phy80211`);
};

function get_phy_name(ifname) {
	if (ifname == null)
		return null;

	let name = readfile(`/sys/class/net/${ifname}/phy80211/name`);
	if (name == null)
		return null;

	name = rtrim(name);

	return length(name) > 0 ? name : null;
};

/* ============================================================
 * WPS iface 映射
 * 驱动接口名（ra0/ra1/rai0/rai1/apcli0/...）-> UCI section 名
 * （default_MT7992_1_1 / wifinetN），供 hostapd_wps_er_action 使用。
 * ============================================================ */
function load_iface_wps() {
	let m = {};
	let content = readfile(IFACE_WPS_FILE);

	if (content == null)
		return m;

	for (let line in split(content, '\n')) {
		let mres = match(line, /^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*$/);

		if (mres != null)
			m[mres[1]] = mres[2];
	}

	return m;
};

/* 内容格式与旧文件一致：每行 "<ifname> <section>"，按 ifname 排序 */
function save_iface_wps(m) {
	let out = '';

	for (let ifn in sort(keys(m)))
		out += `${ifn} ${m[ifn]}\n`;

	writefile(IFACE_WPS_FILE, out);
};

/* ============================================================
 * mtk service_misc
 * ============================================================ */
function find_first_card_profile(devs) {
	let best_name = null;
	let best_path = null;

	for (let name, dev in devs?.[l1dat.DEV_RINDEX] ?? {}) {
		if (dev?.profile_path == null)
			continue;

		if (best_name == null || name < best_name) {
			best_name = name;
			best_path = dev.profile_path;
		}
	}

	return best_path;
};

/* ============================================================
 * .dat 写入助手
 * ============================================================ */
function cfg2dat(cfg) {
	let t = type(cfg);

	if (t == 'bool')
		return cfg ? 1 : 0;

	if (t == 'int' || t == 'double' || t == 'string')
		return cfg;

	/* 与原 Lua 一致：其它类型（array/object）返回 nil/null */
	return null;
};

function set_dev_dat(dats, dat_key, cfg) {
	if (cfg != null)
		dats[dat_key] = cfg2dat(cfg);
};

function bssid_tokens(value, count) {
	let values = [];
	for (let i = 0; i < count; i++)
		push(values, cfg2dat(value));
	return join(';', values);
};

function set_dat(dats, apidx, dat_key, cfg) {
	if (cfg != null)
		dats[dat_key] = dat.token_set(dats[dat_key], apidx, cfg2dat(cfg));
};

function set_idx_dat(dats, apidx, dat_key, cfg) {
	if (cfg != null)
		dats[`${dat_key}${apidx}`] = cfg;
};

function htmode_starts(cfg, n, prefix) {
	let htmode = cfg?.config?.htmode;

	if (type(htmode) != 'string')
		return false;

	return substr(htmode, 0, n) == prefix;
};

function is_n_mode(cfg) {
	return htmode_starts(cfg, 2, 'HT');
};

function is_ac_mode(cfg) {
	return htmode_starts(cfg, 3, 'VHT');
};

function is_ax_mode(cfg) {
	return htmode_starts(cfg, 2, 'HE');
};

function is_be_mode(cfg) {
	return htmode_starts(cfg, 3, 'EHT');
};

/* ucode 没有多返回值，用对象代替 Lua 的 vif_num, ap_num, apcli_num */
function vif_count(cfg) {
	let vif_num = 0;
	let ap_num = 0;
	let apcli_num = 0;
	let ifaces = cfg?.interfaces ?? {};

	for (let _, v in ifaces) {
		vif_num++;

		if (v?.config?.mode == 'ap')
			ap_num++;
		else if (v?.config?.mode == 'sta')
			apcli_num++;
	}

	return { vif: vif_num, ap: ap_num, apcli: apcli_num };
};

function mtwifi_cfg_foreach_vif(cfg, mode, func) {
	if (cfg?.interfaces == null || func == null)
		return;

	/* 和 Lua 的 table.sort(keys) 一样，按 section 名排序保证顺序确定 */
	for (let k in sort(keys(cfg.interfaces))) {
		let v = cfg.interfaces[k];

		if (v?.config?.mode == mode)
			func(v);
	}
};

/* ============================================================
 * cfg80211 tool
 * ============================================================ */
function __exec_cfg80211_tool(ifname, key, val) {
	let tool = exists('/usr/sbin/mwctl') ? '/usr/sbin/mwctl' : null;

	if (tool == null) {
		log_syslog(`no cfg80211 tool found for ${ifname}`);
		die('VENDOR_TOOL_UNAVAILABLE');
	}

	if (type(val) == 'bool')
		val = val ? '1' : '0';

	/* 原 Lua 用 string.format("%q %q set %q=%q", ...)，ucode 的 sprintf
	 * 不支持 %q，改用 shell 单引号转义（语义相同） */
	let cmd = `${tool} ${shell_quote(ifname)} set ${shell_quote('' + key + '=' + val)}`;

	/* Do not log private wireless command arguments. */
	if (system(cmd) != 0)
		die('VENDOR_OPTION_APPLY_FAILED');
};


function mtwifi_cfg_cfg80211_tool_hook(cfg) {
	const ap_hook = (v) => {
		if (v?.config == null || truthy(v.config.disabled) || v.config.ifname == null)
			return;

		let vif = v.config.ifname;

		if (v.config.multi_ap == 1 || v.config.multi_ap == 2) {
			if (truthy(v.config.isolate)) {
				log_syslog(`multi_ap backhaul cannot combine with isolate_clients; ignoring multi_ap for ${vif}`);
			} else {
				__exec_cfg80211_tool(vif, 'fhbss', v.config.multi_ap == 2 ? '0' : '1');
				__exec_cfg80211_tool(vif, 'bhbss', v.config.multi_ap == 2 ? '1' : '0');
			}
		}
	};

	mtwifi_cfg_foreach_vif(cfg, 'ap', ap_hook);
};

/* ============================================================
 * driver_up / driver_down / reinstall
 * ============================================================ */

/*
 * 对应原 Lua 的 mtwifi_up()。
 * 原 Lua 的第三个参数 is_dbdc 是 netifd handler 传进来的，这里作为可选的
 * 第三个参数保留：handler 传 true 时会执行 DBDC 主卡 init（原行为），
 * 只传两个参数时跳过（由 handler 自己决定）。
 */
export function driver_up(devname, payload) {
	mtwifi_cfg_cfg80211_tool_hook(payload);
	/* WHNAT is adapter state; updating its profile alone is insufficient
	 * while sibling bands keep that adapter running. Use its native setter.
	 */
	let dev = get_dev(l1dat.load_cached(), devname);
	let profile = dev ? dat.load_profile(dev.profile_path) : null;
	for (let _, v in payload.interfaces ?? {}) {
		if (v.config.disabled) continue;
		if (profile?.WHNAT != null)
			__exec_cfg80211_tool(v.config.ifname, 'whnat_en', profile.WHNAT);
		break;
	}
	mtwifi_cfg_foreach_vif(payload, 'ap', (v) => {
		let ifn = shell_quote(v.config.ifname);
		if (v.config.kicklow != null)
			__exec_cfg80211_tool(v.config.ifname, 'KickStaRssiLow', v.config.kicklow);
		if (v.config.assocthres != null)
			if (system(`/usr/sbin/mwctl dev ${ifn} set assocreq_rssi_thres ${shell_quote(v.config.assocthres)}`))
				die('ASSOC_RSSI_APPLY_FAILED');
	});
};

export function driver_down(devname, payload) {
	/* netifd and wpad own interfaces and daemons; never stop sibling radios. */
};

/* ============================================================
 * set_chip_cfg
 * ============================================================ */
function set_chip_cfg(cfg, dats, devs, dev_name, plan) {
	if (cfg?.config == null || !truthy(cfg.config.dbdc_main))
		return;

	for (let k, v in defs.chip_cfgs) {
		set_dev_dat(dats, v[0], cfg.config[k]);
	}

	let mydev = get_dev(devs, payload_device(dev_name, cfg));
	if (mydev == null) {
		log('set_chip_cfg: device not found in L1 profile');
		return;
	}

	for (let k, v in devs?.[l1dat.DEV_RINDEX] ?? {}) {
		if (k == dev_name || v?.INDEX != mydev.INDEX || v?.mainidx != mydev.mainidx)
			continue;

		let dev_dats = dat.load_profile(v.profile_path);
		if (dev_dats == null) {
			log(`set_chip_cfg: cannot open ${v.profile_path}`);
			continue;
		}

		for (let _, j in defs.chip_cfgs)
			set_dev_dat(dev_dats, j[0], dats[j[0]]);

		plan.profiles[v.profile_path] = dev_dats;
	}
};

/* ============================================================
 * basic rate
 * band: "2g" or "5g/6g", legacy_rates: 0/1, cell_density: 0~3
 * 对应驱动 mlme.c 的 UpdateBasicRateBitmap()，a-band/GN_MIXMODE 下
 * 强制 6,12,24M(336)。
 * ============================================================ */
function get_basic_rate(band, cell_density, legacy_rates, w_mode) {
	let cd = num_or(cell_density, 0);
	const rate_map = { '0': 336, '1': 336, '2': 320, '3': 256 };

	if (band == '2g') {
		if (legacy_rates == 0 && cd == 0) {
			if (w_mode == 1)		/* B only */
				return 3;
			else if (w_mode == 4)		/* G only */
				return 351;
			else				/* N only (2.4G) / B/G/N mixed */
				return 15;
		} else if (legacy_rates == 1 && cd <= 2) {
			/* Lua 的 ({15, 12, 8})[cell_density + 1] */
			const basic_rates = [ 15, 12, 8 ];

			return basic_rates[cd] ?? 15;
		}
	}

	return rate_map[cd] ?? 336;
};

/* ============================================================
 * 枚举/加密/告警助手
 * ============================================================ */

/* 找不到的 encryption 不要直接索引 null（原 Lua 会崩） */
function enc2dat_lookup(enc, sae_ext_key, gcmp256) {
	if (enc == null)
		return null;

	let entry = defs.enc2dat[enc] ?? null;
	if (entry == null)
		return null;

	/* 旧格式：[ AuthMode, EncrypType ] */
	if (type(entry) == 'array')
		return entry;

	/*
	 * 新格式：{ ext: [ AuthMode, EncrypType ], plain: [ AuthMode, EncrypType ] }
	 * 显式开启（'1' / true / 1 / 'true' / 'on' / 'yes'）→ ext
	 * 缺省、'0'、false、null、undefined     → plain
	 */
	let on = ('' + sae_ext_key) in [ '1', 'true', 'on', 'yes' ];

	let result = [ ...(on ? (entry.ext ?? entry.plain) : (entry.plain ?? entry.ext)) ];
	/* The AKM flag and the automatic pairwise cipher are independent. */
	if (enc in [ 'sae', 'sae-mixed' ])
		result[1] = truthy(gcmp256) ? 'CCMP128,GCMP256' : 'CCMP128';
	return result;
};

/*
 * auth_server / acct_server 现在是字符串数组（auth_server_addr 的别名）。
 * 原 Lua 把整个表交给 cfg2dat() -> nil -> token_set() -> nil，结果
 * RADIUS_Server 被整个丢掉；这里只取第一个并告警。
 */
function first_server(v, what) {
	if (v == null)
		return null;

	if (type(v) == 'array') {
		if (length(v) > 1)
			log(`${what}: ${length(v)} entries given, only the first one is used`);

		return v[0] ?? null;
	}

	return v;
};

function igmp_snooping_get() {
	try {
		return uci.cursor().get('network', '@device[0]', 'igmp_snooping') ?? '';
	} catch (e) {
		log(`failed to query igmp_snooping: ${e}`);
		return '';
	}
};

/* ============================================================
 * write_dat：生成/写回 .dat
 *
 * 返回 { ok, reinstall, changed }：
 *   ok        配置已写入 .dat，handler 可以继续 down/up 驱动
 *   reinstall 有 defs.reinstall_cfgs 里的键变化，需要 rmmod/modprobe
 *   changed   .dat 内容发生了变化
 * 原 Lua 会自己执行 rmmod/modprobe 和 "/sbin/wifi up" 递归，这里只返回
 * 标志，由 handler 决定（handler 需要先知道结果再决定是否启动 hostapd）。
 * ============================================================ */
export function prepare_dat(devname, payload) {
	let result = { ok: false, reinstall: false, changed: false, profiles: {}, files: [] };

	if (exists(REINSTALL_LOCK)) {
		log_syslog('reinstall in progress, skip nested setup');
		return result;
	}


	let dev_name = payload_device(devname, payload);
	let devs = l1dat.load_cached();
	let dev = get_dev(devs, dev_name);

	if (dev == null) {
		log(`write_dat: device ${dev_name} not found in L1 profile`);
		return result;
	}

	let profile = dev.profile_path;
	if (profile == null) {
		log(`write_dat: no profile_path for device ${dev_name}`);
		return result;
	}

	let dats = dat.load_profile(profile);
	if (dats == null) {
		log(`write_dat: profile ${profile} open failed`);
		return result;
	}

	result.profiles[profile] = dats;
	let dats_orig = dat.load_profile(profile);
	let counts = vif_count(payload);
	let ifaces = payload.interfaces ?? {};

	if (counts.vif == 0) {
		log('not valid vif found!');
		return result;
	}

	if (counts.ap > defs.max_mbssid) {
		log('too many mbssid vifs!');
		return result;
	}

	if (counts.apcli > 1) {
		log('only support one apcli vif! aborting setup');
		return result;
	}

	dats.BssidNum = counts.ap > 0 ? counts.ap : 1;

	if (type(payload?.config?.htmode) != 'string') {
		log('invalid htmode!');
		return result;
	}

	let band = payload.config.band;
	let wmode;

	if (band == '2g') {
		if (is_be_mode(payload))
			wmode = 22;	/* PHY_11BE_24G */
		else if (is_ax_mode(payload))
			wmode = 16;	/* PHY_11AX_24G */
		else if (is_n_mode(payload))
			wmode = 9;	/* PHY_11BGN_MIXED */
		else
			wmode = payload.config.hw_mode == '11b' ? 1 : 0;	/* B only or B/G */
	} else if (band == '5g') {
		if (is_be_mode(payload))
			wmode = 23;	/* PHY_11BE_5G */
		else if (is_ax_mode(payload))
			wmode = 17;	/* PHY_11AX_5G */
		else if (is_ac_mode(payload))
			wmode = 14;	/* PHY_11VHT_N_A_MIXED */
		else if (is_n_mode(payload))
			wmode = 8;	/* PHY_11AN_MIXED */
		else
			wmode = 2;	/* PHY_11A */
	} else if (band == '6g') {
		if (is_be_mode(payload))
			wmode = 24;	/* PHY_11BE_6G */
		else if (is_ax_mode(payload))
			wmode = 18;	/* PHY_11AX_6G */
	}

	if (wmode == null) {
		log('invalid wireless mode!');
		return result;
	}

	let bwres = payload.config.htmode == 'NOHT' ? [ '20', '20' ] :
		match(payload.config.htmode, /([0-9]+)/);

	if (bwres == null) {
		log('invalid bandwidth!');
		return result;
	}

	let bw = bwres[1];
	let split = payload.config.htmode in [ 'VHT80_80', 'HE80_80' ];
	let extension = match(payload.config.htmode, /40([+-])$/);
	if (extension) dats.HT_EXTCHA = extension[1] == '+' ? 1 : 0;

	dats.HT_BW = 0;
	dats.VHT_BW = 0;
	dats.EHT_ApBw = 0;

	if (bw == '40') {
		dats.HT_BW = 1;
		dats.VHT_BW = 0;
		dats.EHT_ApBw = 1;
		dats.HT_BSSCoexistence = truthy(payload.config.noscan) ? 0 : 1;
	} else if (bw == '80') {
		dats.HT_BW = 1;
		dats.VHT_BW = 1;
		dats.EHT_ApBw = 2;
	} else if (bw == '160') {
		dats.HT_BW = 1;
		dats.VHT_BW = 2;
		dats.EHT_ApBw = 3;
	} else if (bw == '240') {
		dats.HT_BW = 1;
		dats.VHT_BW = 2;
		dats.EHT_ApBw = 4;
	/* } else if (bw == '320-1' && band == '5g') {
		dats.ext_eht_mode = 1;
	} else if (bw == '320-2' && band == '5g') {
		dats.ext_eht_mode = 2; */
	} else if (bw == '320' && band == '6g') {
		dats.HT_BW = 1;
		dats.VHT_BW = 2;

		if (is_be_mode(payload))
			dats.EHT_ApBw = 4;
		else if (is_ax_mode(payload))
			dats.EHT_ApBw = 3;
	}
	let secondary = [];
	for (let i = 0; i < +dats.BssidNum; i++)
		push(secondary, split ? '' + payload.config.channel2 : '0');
	dats.VHT_Sec80_Channel = join(';', secondary);
	if (split) {
		dats.VHT_BW = 3;
		dats.EHT_ApBw = 0;
	}

	/* setup apcli */
	dats.ApCliWirelessMode = '';
	dats.ApCliEnable = 0;
	dats.ApCliSsid = '';
	dats.AutoConnect = 0;
	dats.ApCliBssid = '';
	dats.MACRepeaterEn = 0;
	dats.ApcliMloDisable = 1;
	dats.ApcliMldAddr = '';
	dats.ApCliMWDS = 0;
	dats.ApcliHostapdWDSEnable = 0;
	dats.ApCliUAPSDCapable = 0;
	dats.ApcliMacAddress = '';
	dats.ApCliAuthMode = '';
	dats.ApCliEncrypType = '';
	dats.ApCliWPAPSK = '';
	dats.ApCliPMFMFPC = 0;
	dats.ApCliPMFMFPR = 0;
	dats.ApCliPMFSHA256 = 0;
	dats.ApCliPweMethod = 0;
	dats.ApCliPMFSAQ_Time = 1000;
	dats.ApCliPMFSAQ_ConfTime = 200;
	dats.ApCliOCVSupport = 0;
	dats.ApCliMuMimoDlEnable = 0;
	dats.ApCliMuMimoUlEnable = 0;
	dats.ApCliMuOfdmaDlEnable = 1;
	dats.ApCliMuOfdmaUlEnable = 1;
	dats.ApCliPpMuMimoDlEnable = 0;
	dats.ApCliPpMuMimoUlEnable = 0;
	dats.ApCliPpOfdmaDlEnable = 1;
	dats.ApCliPpOfdmaUlEnable = 1;

	/* 原 Lua 用 pairs() 取第一个 sta vif 后就 break，这里按 key 排序保证确定 */
	for (let iface_key in sort(keys(ifaces))) {
		let v = ifaces[iface_key];

		if (v?.config?.mode != 'sta')
			continue;

		dats.ApCliWirelessMode = wmode;

		if (!truthy(v.config.disabled)) {
			dats.ApCliEnable = 1;

			if (!truthy(v.config.mlo)) {
				dats.ApcliMloDisable = 1;
				dats.ApcliMacAddress = v.config.macaddr;
			} else {
				dats.ApcliMloDisable = 0;
				dats.ApcliMldAddr = v.config.macaddr;
			}
		}

		dats.ApCliMWDS = truthy(v.config.mwds) ? 1 : 0;


		/* hostapd 4-addr WDS（UCI wds=1, sta-wds）*/
		if (v.config.wds === true || v.config.wds == '1')
			dats.ApcliHostapdWDSEnable = 1;

		dats.ApCliSsid = lua_or(v.config.ssid, '');
		dats.AutoConnect = has_text(v.config.ssid) ? 0 : 1;
		dats.ApCliBssid = lua_or(v.config.bssid, '');
		dats.MACRepeaterEn = has_text(v.config.bssid) ? 1 : 0;
		dats.ApCliUAPSDCapable = lua_or(v.config.uapsd, 0);

		let encinfo = enc2dat_lookup(v.config.encryption, v.config.sae_ext_key, v.config.gcmp256);

		if (encinfo == null) {
			log(`unknown encryption "${v.config.encryption}" on ${iface_key}, skip ApCliAuthMode`);
		} else {
			dats.ApCliAuthMode = encinfo[0];
			dats.ApCliEncrypType = encinfo[1];
		}

		dats.ApCliWPAPSK = lua_or(v.config.key, '');

		let w_mode = dats.ApCliWirelessMode;

		if (w_mode >= 16 && w_mode <= 21) {
			dats.ApCliMuMimoDlEnable = truthy(v.config.mumimo_dl) ? 1 : 0;
			dats.ApCliMuMimoUlEnable = truthy(v.config.mumimo_ul) ? 1 : 0;
			dats.ApCliMuOfdmaDlEnable = truthy(v.config.ofdma_dl) ? 1 : 0;
			dats.ApCliMuOfdmaUlEnable = truthy(v.config.ofdma_ul) ? 1 : 0;
		} else if (w_mode >= 22 && w_mode <= 27) {
			dats.ApCliPpMuMimoDlEnable = truthy(v.config.mumimo_dl) ? 1 : 0;
			dats.ApCliPpMuMimoUlEnable = truthy(v.config.mumimo_ul) ? 1 : 0;
			dats.ApCliPpOfdmaDlEnable = truthy(v.config.ofdma_dl) ? 1 : 0;
			dats.ApCliPpOfdmaUlEnable = truthy(v.config.ofdma_ul) ? 1 : 0;
		}

		dats.ApCliPweMethod = (w_mode == 18 || w_mode == 24) ? 2 : 0;

		let ieee80211w = tostr(v.config.ieee80211w);
		if (ieee80211w == '1' || dats.ApCliAuthMode == 'WPA2PSKWPA3PSK' ||
		    dats.ApCliAuthMode == 'WPA2PSKWPA3PSK,WPA3PSK_EXT') {
			dats.ApCliPMFMFPC = 1;
			dats.ApCliPMFMFPR = 0;
			dats.ApCliPMFSHA256 = 0;
		} else if (ieee80211w == '2' || dats.ApCliAuthMode == 'OWE' ||
		           dats.ApCliAuthMode == 'WPA3PSK' || dats.ApCliAuthMode == 'WPA3PSK_EXT' ||
		           dats.ApCliAuthMode == 'WPA3-192' || dats.ApCliAuthMode == 'WPA3' ||
			   dats.ApCliAuthMode == 'WPA3PSK,WPA3PSK_EXT') {
			dats.ApCliPMFMFPC = 1;
			dats.ApCliPMFMFPR = 1;
			dats.ApCliPMFSHA256 = dats.ApCliAuthMode == 'WPA3' ? 1 : 0;
		}

		if (ieee80211w != '0') {
			dats.ApCliPMFSAQ_Time = v.config.ieee80211w_max_timeout;
			dats.ApCliPMFSAQ_ConfTime = v.config.ieee80211w_retry_timeout;
			dats.ApCliOCVSupport = v.config.ocv;
		}

		break;
	}

	set_chip_cfg(payload, dats, devs, dev_name, result);

	let country = payload.config.country ?? payload.config.country_code;

	if (type(country) == 'string' && length(country) == 2) {
		dats.CountryCode = country;

		let region = defs.countryRegions[country];

		if (region == null) {
			log(`invalid country code ${country}`);
			return result;
		}

		if (band == '2g') {
			dats.CountryRegion = region[0];
		} else if (band == '5g') {
			dats.CountryRegionABand = region[1];

			if (country == '00' || country == 'US')
				dats.AutoChannelSkipList = '100;104;108;112;116;120;124;128;132;136;140;144;169;173;177';
			else
				dats.AutoChannelSkipList = '';
		} else if (band == '6g') {
			dats.PweMethod = 2;
			dats.CountryRegionABand = region[2];
		}
	}

	if (payload.config.channel == 'auto') {
		dats.AutoChannelSelect = 3;
		dats.Channel = 0;
	} else {
		dats.AutoChannelSelect = 0;
		dats.Channel = payload.config.channel;
	}

	/* 原 Lua 直接比较 cfg.config.txpower < 100，txpower 是字符串时会崩 */
	let txpower = num_or(payload.config.txpower, null);
	if (txpower != null && txpower < 100) {
		dats.PERCENTAGEenable = 1;
		dats.TxPower = txpower;
	} else if (txpower != null) {
		dats.PERCENTAGEenable = 0;
		dats.TxPower = 100;
	}

	if (truthy(payload.config.mu_beamformer)) {
		dats.ETxBfEnCond = 1;
		dats.MUTxRxEnable = dats.ApCliEnable == 1 ? 3 : 1;
		dats.ITxBfEn = 1;
	} else if (payload.config.mu_beamformer != null) {
		dats.ETxBfEnCond = 0;
		dats.MUTxRxEnable = 0;
		dats.ITxBfEn = 0;
	}
	if (payload.config.mu_beamformer != null) {
		payload.config.he_mu_beamformer = payload.config.mu_beamformer;
		payload.config.eht_mu_beamformer = payload.config.mu_beamformer;
	}

	/* HE individual/broadcast TWT and EHT restricted TWT are independent. */
	if (payload.config.twt != null)
		dats.TWTSupport = payload.config.twt;
	if (payload.config.eht_restricted_twt != null)
		dats.EHT_ApRestrictedTwt = bssid_tokens(payload.config.eht_restricted_twt, int(dats.BssidNum));
	let twt = int(dat.token_get(dats.TWTSupport, 1, '0'));
	payload.config.he_twt_responder = !!(twt & 1);
	if (payload.config.he_ldpc != null)
		dats.HeLdpc = bssid_tokens(payload.config.he_ldpc, int(dats.BssidNum));

	set_dev_dat(dats, 'MapMode', payload.config.map_mode);
	if (payload.config.map_mode == '1') {
		dats.SREnable = 0;
		dats.SRMode = 0;
	}

	const region_map = { 'CN': 'CHN', 'US': 'FCC', 'JP': 'JAP', 'KR': 'KR', 'FR': 'CE', 'IE': 'CE', 'AU': 'CE' };
	dats.RDRegion = region_map[country] ?? 'CE';
	if (country == 'US' || country == 'KR')
		dats.EDCCARegion = 1;
	else if (country == 'JP')
		dats.EDCCARegion = 3;
	else if (country == 'DE')
		dats.EDCCARegion = 4;
	else
		dats.EDCCARegion = 0;

	if (payload.config.doth != null)
		set_dev_dat(dats, band == '2g' ? 'SeamlessCSA' : 'IEEE80211H', payload.config.doth);
	if (band == '5g' && payload.config.doth === false) {
		dats.DfsEnable = 0;
		dats.DfsZeroWait = 0;
		dats.DfsDedicatedZeroWait = 0;
		dats.DfsZeroWaitDefault = 0;
	} else if (band == '5g') {
		set_dev_dat(dats, 'DfsEnable', payload.config.dfs);
		if (payload.config.zw_dfs != null) {
			let enable = payload.config.zw_dfs && +dats.IEEE80211H == 1 && +dats.DfsEnable == 1;
			dats.DfsZeroWait = enable && +dats.MACRepeaterEn != 1 ? 1 : 0;
			dats.DfsDedicatedZeroWait = enable ? 2 : 0;
			dats.DfsZeroWaitDefault = enable ? 1 : 0;
		}
	}
	if (band == '5g')
		payload.config.ieee80211h = +dats.IEEE80211H == 1;

	/* Resolve WHNAT through L1 ownership, never through a global filename glob. */
	for (let group in l1dat.whnat_groups(devs)) {
		if (!group.profiles[profile])
			continue;
		let sections = uci.cursor().get_all('wireless') ?? {};
		let value = null;
		for (let name, sec in sections)
			if ((sec.devname ?? name) == group.master)
				value = sec.whnat;
		if (dev_name == group.master && payload.config.whnat != null)
			value = payload.config.whnat;
		if (value == null || value === '') value = '1';
		if (!(value in [ '0', '1', 0, 1, false, true ]))
			return result;
		value = (value === '1' || value === 1 || value === true) ? '1' : '0';
		let paths = { ...group.profiles, [group.path]: true };
		for (let path in paths) {
			let cfgs = result.profiles[path] ?? dat.load_profile(path);
			if (!cfgs)
				return result;
			cfgs.WHNAT = value;
			result.profiles[path] = cfgs;
		}
	}

	/* in mt_wifi cmm_cfg.c set_datcfg_ack_cts_timeout */
	dats.ACK_CTS_TOUT_EN = payload.config.distance > 0 ? 1 : 0;
	dats.Distance = dats.ACK_CTS_TOUT_EN == 1 ? lua_or(payload.config.distance, 0) : 0;
	dats.BasicRate = get_basic_rate(band, payload.config.cell_density ?? 0,
	                                truthy(payload.config.legacy_rates) ? 1 : 0, wmode);
	dats.BGProtection = truthy(payload.config.legacy_rates) ? 1 : 0;
	set_dev_dat(dats, 'Vht1024QamSupport', payload.config.vht_1024);
	set_dev_dat(dats, 'TxBurst', payload.config.tx_burst);
	set_dev_dat(dats, 'TxPreamble', payload.config.tx_preamble);

	/* reset vif cfgs to default */
	const preserve = [ 'HT_AMSDU', 'HT_AutoBA', 'APSDCapable',
		'MuMimoDlEnable', 'MuMimoUlEnable', 'MuOfdmaDlEnable', 'MuOfdmaUlEnable',
		'PpMuMimoDlEnable', 'PpMuMimoUlEnable', 'PpOfdmaDlEnable', 'PpOfdmaUlEnable' ];
	for (let k, v in defs.vif_cfgs) {
		if (k in preserve && dats[k] != null)
			continue;
		dats[k] = '';

		for (let i = 1; i <= counts.ap; i++)
			dats[k] = dat.token_set(dats[k], i, v);
	}

	for (let k, v in defs.vif_cfgs_idx) {
		for (let i = 1; i <= defs.max_mbssid; i++)
			dats[`${k}${i}`] = '';

		for (let i = 1; i <= counts.ap; i++)
			dats[`${k}${i}`] = v;
	}

	for (let vif_table in [ defs.vif_mac, defs.vif_acl ]) {
		for (let k, v in vif_table) {
			if (k == 'MacAddress') {
				for (let i = 1; i <= counts.ap - 1; i++)
					dats[`${k}${i}`] = v;

				if (counts.ap < defs.max_mbssid) {
					for (let i = counts.ap; i <= defs.max_mbssid - 1; i++)
						dats[`${k}${i}`] = '';
				}
			} else {
				for (let i = 0; i <= counts.ap - 1; i++)
					dats[`${k}${i}`] = v;

				if (counts.ap < defs.max_mbssid) {
					for (let i = counts.ap; i <= defs.max_mbssid - 1; i++)
						dats[`${k}${i}`] = '';
				}
			}
		}
	}

	/* setup vif cfgs */
	let apidx = 1;
	let ap_index = 0;

	for (let iface_key in sort(keys(ifaces))) {
		let v = ifaces[iface_key];

		if (v?.config?.mode != 'ap')
			continue;
		v.config.preamble = +dats.TxPreamble != 0;

		let ifname = v.config.ifname;
		let igmp_snooping = igmp_snooping_get();
		let mac = v.config.macaddr;
		let mld_group = v.config.mldgroup ?? (v.config.mlo ? 1 : 0);
		set_dat(dats, apidx, 'MldGroup', mld_group);
		if (mld_group > 0) {
			set_idx_dat(dats, mld_group, 'MldAddr', lua_or(mac, ''));
		} else {
			if (ap_index == 0)
				dats.MacAddress = has_text(mac) ? mac : dats.MacAddress_Default;
			else
				set_idx_dat(dats, apidx - 1, 'MacAddress', lua_or(mac, ''));
		}

		set_dat(dats, apidx, 'ApMWDS', truthy(v.config.mwds) ? 1 : 0);
		/* __exec_cfg80211_tool(ifname, 'mwds enable', truthy(mwds) ? '1' : '0'); */

		set_idx_dat(dats, apidx, 'SSID', v.config.ssid);
		set_idx_dat(dats, apidx, 'WPAPSK', lua_or(v.config.key, ''));
		set_dat(dats, apidx, 'NoForwarding', lua_or(v.config.isolate, 0));
		set_dat(dats, apidx, 'HideSSID', v.config.hidden);
		set_dat(dats, apidx, 'WmmCapable', v.config.wmm);
		set_dat(dats, apidx, 'RekeyInterval', v.config.wpa_group_rekey);
		set_dat(dats, apidx, 'HT_AMSDU', v.config.amsdu);
		set_dat(dats, apidx, 'HT_AutoBA', v.config.autoba);
		set_dat(dats, apidx, 'APSDCapable', v.config.uapsd);
		v.config.uapsd_advertisement_enabled = +dat.token_get(dats.APSDCapable, apidx, '0') == 1;
		set_dat(dats, apidx, 'RTSThreshold', v.config.rts);
		set_dat(dats, apidx, 'FragThreshold', v.config.frag);
		set_dat(dats, apidx, 'DtimPeriod', v.config.dtim_period);
		set_dat(dats, apidx, 'WirelessMode', wmode);
		set_dat(dats, apidx, 'RRMEnable', v.config.ieee80211k);
		set_dat(dats, apidx, 'RRMNeighbor', v.config.rrm_neighbor_report);
		set_dat(dats, apidx, 'WNMEnable', v.config.bss_transition);
		set_dat(dats, apidx, 'WNMNotifyEnable', v.config.wnm_notify);
		set_dat(dats, apidx, 'ProxyARPEnable', v.config.proxy_arp);
		set_dat(dats, apidx, 'FtSupport', v.config.ieee80211r);
		set_dat(dats, apidx, 'reliable_11r', v.config.reliable_11r);
		set_dat(dats, apidx, 'FtOtd', v.config.ft_over_ds);
		set_dat(dats, apidx, 'IgmpSnEnable', igmp_snooping);
		set_idx_dat(dats, apidx, 'FtMdId', v.config.mobility_domain);


		if (is_be_mode(payload)) {
			set_dat(dats, apidx, 'PpMuMimoDlEnable', v.config.mumimo_dl);
			set_dat(dats, apidx, 'PpMuMimoUlEnable', v.config.mumimo_ul);
			set_dat(dats, apidx, 'PpOfdmaDlEnable', v.config.ofdma_dl);
			set_dat(dats, apidx, 'PpOfdmaUlEnable', v.config.ofdma_ul);
			set_dat(dats, apidx, 'HT_BAWinSize', 1024);
		} else if (is_ax_mode(payload)) {
			set_dat(dats, apidx, 'MuMimoDlEnable', v.config.mumimo_dl);
			set_dat(dats, apidx, 'MuMimoUlEnable', v.config.mumimo_ul);
			set_dat(dats, apidx, 'MuOfdmaDlEnable', v.config.ofdma_dl);
			set_dat(dats, apidx, 'MuOfdmaUlEnable', v.config.ofdma_ul);
			set_dat(dats, apidx, 'HT_BAWinSize', 256);
		} else {
			set_dat(dats, apidx, 'HT_BAWinSize', 64);
		}

		if (v.config.macfilter == 'allow')
			set_idx_dat(dats, apidx - 1, 'AccessPolicy', 1);
		else if (v.config.macfilter == 'deny')
			set_idx_dat(dats, apidx - 1, 'AccessPolicy', 2);

		if (truthy(v.config.maclist)) {
			let maclist = '';
			let i = 0;

			for (let entry in v.config.maclist) {
				i++;

				if (i > defs.max_acl_entry)
					break;

				maclist = length(maclist) > 0 ? maclist + ';' + entry : entry;
			}

			set_idx_dat(dats, apidx - 1, 'AccessControlList', maclist);
		}

		let encinfo = enc2dat_lookup(v.config.encryption, v.config.sae_ext_key, v.config.gcmp256);
		let authmode = encinfo != null ? encinfo[0] : null;

		if (encinfo == null) {
			log(`unsupported encryption on ${iface_key}`);
			return result;
		} else {
			set_dat(dats, apidx, 'AuthMode', authmode);
			set_dat(dats, apidx, 'EncrypType', encinfo[1]);
		}

		let wps = tostr(v.config.wps_pushbutton);

		if (wps == '1') {
			set_dat(dats, apidx, 'WscConfMode', 7);
			set_dat(dats, apidx, 'WscConfStatus', 1);

			let pin = lua_or(v.config.wps_pin, '');

			set_dat(dats, apidx, 'Wsc4digitPinCode', length('' + pin) <= 4 ? 1 : 0);
			set_dat(dats, apidx, 'WscVendorPinCode', lua_or(v.config.pin, ''));
		} else if (wps == '2') {
			set_dat(dats, apidx, 'WscConfMode', 7);
			set_dat(dats, apidx, 'WscConfStatus', 2);
		}

		let ieee80211w = tostr(v.config.ieee80211w);
		if (ieee80211w == '1' || authmode == 'WPA2PSKWPA3PSK' ||
		    authmode == 'WPA2PSKWPA3PSK,WPA3PSK_EXT') {
			set_dat(dats, apidx, 'PMFMFPC', 1);
			set_dat(dats, apidx, 'PMFMFPR', 0);
			set_dat(dats, apidx, 'PMFSHA256', 0);
		} else if (ieee80211w == '2' || authmode == 'OWE' ||
		           authmode == 'WPA3PSK,WPA3PSK_EXT' || authmode == 'WPA3PSK_EXT' ||
		           authmode == 'WPA3PSK' || authmode == 'WPA3' ||
			   authmode == 'WPA3-192' || authmode == 'WPA3PSK,WPA3PSK_EXT') {
			set_dat(dats, apidx, 'PMFMFPC', 1);
			set_dat(dats, apidx, 'PMFMFPR', 1);
			set_dat(dats, apidx, 'PMFSHA256', authmode == 'WPA3' ? 1 : 0);
		}

		if (ieee80211w != '0') {
			set_dat(dats, apidx, 'PMFSAQ_Time', v.config.ieee80211w_max_timeout);
			set_dat(dats, apidx, 'PMFSAQ_ConfTime', v.config.ieee80211w_retry_timeout);
			set_dat(dats, apidx, 'OCVSupport', v.config.ocv);
		}

		if (!(authmode == 'OPEN' || authmode == 'OWE'))
			set_dat(dats, apidx, 'RekeyMethod', 'TIME');

		if (authmode == 'WPA' || authmode == 'WPA2' || authmode == 'WPA1WPA2' ||
		    authmode == 'WPA3WPA2' || authmode == 'WPA3' || authmode == 'WPA3-192') {
			set_idx_dat(dats, apidx, 'NasId', lua_or(v.config.nasid, ''));
			set_idx_dat(dats, apidx, 'RADIUS_Key', lua_or(v.config.auth_secret, ''));
			set_dat(dats, apidx, 'RADIUS_Acct_Key', lua_or(v.config.acct_secret, ''));
			set_dat(dats, apidx, 'own_ip_addr', v.config.ownip);
			set_dat(dats, apidx, 'own_radius_port', v.config.own_radius_port);
			set_dat(dats, apidx, 'PreAuth', v.config.rsn_preauth);
			set_dat(dats, apidx, 'RADIUS_Port', v.config.auth_port);
			set_dat(dats, apidx, 'RADIUS_Server', first_server(v.config.auth_server, 'RADIUS_Server'));
			set_dat(dats, apidx, 'RADIUS_Acct_Server', first_server(v.config.acct_server, 'RADIUS_Acct_Server'));
			set_dat(dats, apidx, 'RADIUS_Acct_Port', v.config.acct_port);
			set_dat(dats, apidx, 'IEEE8021X', (authmode == 'WPA' || authmode == 'WPA2') ? 1 : 0);
		} else {
			set_idx_dat(dats, apidx, 'FtR0khId', lua_or(v.config.nasid, ''));
		}

		apidx++;
		ap_index++;
	}

	let cfg_diff = diff_cfg(dats_orig, dats);

	result.changed = length(keys(cfg_diff)) > 0;
	for (let key in defs.reinstall_cfgs)
		if (cfg_diff[key] != null)
			result.reinstall = true;
	result.path = profile;
	result.dats = dats;
	for (let path, values in result.profiles) {
		let previous = readfile(path);
		let text = dat.render_profile(values, path);
		if (previous == null || text == null)
			return result;
		if (text != previous)
			push(result.files, { path, previous, text });
	}
	result.changed = length(result.files) > 0;
	result.ok = true;

	return result;
};

export function rollback_dat(plan) {
	let ok = true;
	for (let file in reverse(plan.committed ?? []))
		ok = atomic_write(file.path, file.previous) && ok;
	if (ok)
		plan.committed = [];
	return ok;
};

export function commit_dat(plan) {
	if (!plan.ok)
		return false;
	plan.committed = [];
	for (let file in plan.files) {
		if (!atomic_write(file.path, file.text)) {
			rollback_dat(plan);
			return false;
		}
		push(plan.committed, file);
	}
	return true;
};

/* ============================================================
 * iface_wps 映射
 *
 * 对应原 Lua 的 update_iface_wps()：把当前 radio 的旧映射删掉，再把
 * payload.interfaces 里的映射合并进来，写回 /var/run/mtwifi-iface-wps
 * （内容即旧文件格式），同时把结果返回给 handler。
 * devname 可以从 payload.device 取，也可以作为第二个参数传入。
 * ============================================================ */
export function iface_wps_map(payload, devname) {
	if (payload?.interfaces == null)
		return {};

	let map = load_iface_wps();
	let devs = l1dat.load_cached();
	let dev = get_dev(devs, payload_device(devname, payload));

	if (dev == null) {
		log('iface_wps_map: device not found in L1 profile');
		return map;
	}

	let prefixes = [
		dev.main_ifname,	/* ra0 / rai0 */
		dev.ext_ifname,		/* ra / rai */
		dev.apcli_ifname,	/* apcli / apclii */
		dev.wds_ifname,		/* wds / wdsi */
		dev.mesh_ifname,	/* mesh / meshi */
	];
	let keep = {};

	/* 删掉属于当前 radio 的所有旧映射 */
	for (let ifn, sec in map) {
		let drop = false;

		for (let p in prefixes) {
			if (p != null && length(p) > 0 && substr(ifn, 0, length(p)) == p) {
				drop = true;
				break;
			}
		}

		if (!drop)
			keep[ifn] = sec;
	}

	/* 加入当前 interfaces */
	for (let section, v in payload.interfaces) {
		if (v?.config?.ifname != null)
			keep[v.config.ifname] = section;
	}

	save_iface_wps(keep);

	return keep;
};

'use strict';

// SPDX-License-Identifier: GPL-2.0
/*
 * mtwifi ucode support - apcli (STA) 侧的 wpa_supplicant 管理
 *
 * Copyright (C) 2026 nanchuci <nanchuci023@gmail.com>
 *
 * STA interfaces are created explicitly with iw before attaching them to the
 * shared wpad daemon. The cfg80211 config_add/config_remove API supplies the
 * actual daemon PID to netifd; wpa_cli is only used for status and scan actions.
 * Network blocks are rendered by wifi.supplicant.generate().
 */

import * as fs from 'fs';
import * as supplicant from 'wifi.supplicant';
import * as netifd from 'wifi.netifd';
import { log, trim, readfile, shell_quote, sleep, read_pipe, daemon_config_write, capture_files, commit_files, rollback_files } from 'mtwifi.common';

const IW = '/usr/sbin/iw';
const WPA_CTRL_DIR = '/var/run/wpa_supplicant';
const WPA_CLI = '/usr/sbin/wpa_cli';
const SCAN_ACTION = '/usr/share/ucode/mtwifi/scan-action.uc';

/*
 * 与 generate() 输出重复或需要强制覆盖的全局字段前缀。凡是命中这里的行，
 * 都会从原 .conf 里删掉，由我们自己重新生成。
 */
const GLOBAL_DEDUP = [
	/^\s*ctrl_interface\s*=/,
	/^\s*update_config\s*=/,
	/^\s*bss_expiration_scan_count\s*=/,
	/^\s*autoscan\s*=/,
	/^\s*sae_pwe\s*=/,
	/^\s*dpp_config_processing\s*=/,
	/^\s*device_name\s*=/,
	/^\s*device_type\s*=/,
	/^\s*manufacturer\s*=/,
	/^\s*model_name\s*=/,
	/^\s*model_number\s*=/,
	/^\s*serial_number\s*=/,
	/^\s*config_methods\s*=/,
	/^\s*wps_cred_processing\s*=/,
	/^\s*wps_cred_add_sae\s*=/,
	/^\s*ignore_old_scan_res\s*=/,
	/^\s*pmf\s*=/,
];

function global_cli(cmd) {
	return trim(read_pipe(`${WPA_CLI} -g ${WPA_CTRL_DIR}/global ${cmd}`) ?? '');
};

function iface_cli(ifname, cmd) {
	return trim(read_pipe(`${WPA_CLI} -p ${WPA_CTRL_DIR}/ -i ${shell_quote(ifname)} ${cmd}`) ?? '');
};

function wait_for(path, tries) {
	for (let i = 0; i < tries; i++) {
		if (fs.stat(path))
			return true;
		sleep(0.1);
	}

	return false;
};

/* interface_name 列表（wpa_cli interface 输出是以空格分隔的接口名） */
function iface_list() {
	return filter(split(global_cli('interface'), /\s+/), (v) => length(v));
};

function scan_action_stop(ifname) {
	let pidfile = `/var/run/action-${ifname}-scan.pid`;

	if (fs.stat(pidfile)) {
		let pid = trim(readfile(pidfile) ?? '');

		if (match(pid, /^[0-9]+$/) && +pid > 1)
			system(`kill -TERM ${+pid} 2>/dev/null`);

		fs.unlink(pidfile);
	}
};

function scan_action_start(ifname) {
	let pidfile = `/var/run/action-${ifname}-scan.pid`;
	let ctrl = `${WPA_CTRL_DIR}/${ifname}`;

	if (!fs.stat(SCAN_ACTION))
		return;

	if (!wait_for(ctrl, 30)) {
		log(`ctrl socket for ${ifname} not ready, skip scan action`);
		return;
	}

	scan_action_stop(ifname);
	system(`${WPA_CLI} -p ${WPA_CTRL_DIR}/ -i ${shell_quote(ifname)} -a ${shell_quote(SCAN_ACTION)} -B -P ${shell_quote(pidfile)}`);
	log(`scan action attached to ${ifname}`);
};

function normalize_band(band) {
	if (band == null)
		return null;
	band = lc(`${band}`);
	return band == '2.4g' ? '2g' : band;
};

/* 依次从 iface_data.config / iface_data / data.config 里取值 */
function pick_global(iface_data, data, key) {
	if (iface_data?.config?.[key] != null)
		return iface_data.config[key];
	if (iface_data?.[key] != null)
		return iface_data[key];
	if (data?.config?.[key] != null)
		return data.config[key];
	return null;
};

function is_map_mode(data) {
	let m = data?.config?.map_mode;
	return m != null && m != '' && m != '0' && m != 0;
};

/*
 * 按 SDK Lua 的逻辑，生成旧 wpad 路径下需要的全局字段列表。
 */
function build_global(iface_data, data) {
	let out = [];
	let map = is_map_mode(data);

	/* 基础固定项 */
	push(out, `ctrl_interface=${WPA_CTRL_DIR}`);
	push(out, 'update_config=1');
	push(out, 'bss_expiration_scan_count=1');

	/* DPP */
	let dpp = pick_global(iface_data, data, 'dpp_config_processing');
	if (dpp != null && dpp != '')
		push(out, `dpp_config_processing=${dpp}`);

	/* WPS 设备信息（缺省走 SDK 默认值） */
	let v;

	v = pick_global(iface_data, data, 'wps_device_name');
	push(out, `device_name=${v != null && v != '' ? v : 'Wireless station'}`);

	v = pick_global(iface_data, data, 'wps_device_type');
	push(out, `device_type=${v != null && v != '' ? v : '6-0050F204-1'}`);

	v = pick_global(iface_data, data, 'wps_manufacturer');
	push(out, `manufacturer=${v != null && v != '' ? v : 'MediaTek Inc.'}`);

	push(out, 'model_name=MediaTek Wireless Access Point');
	push(out, 'model_number=MT7988');
	push(out, 'serial_number=12345678');
	push(out, 'config_methods=display virtual_push_button keypad physical_push_button');

	/* WPS 凭据处理：UCI 优先，MAP 场景下默认 1 */
	v = pick_global(iface_data, data, 'wps_cred_processing');
	if (v != null && v != '')
		push(out, `wps_cred_processing=${v}`);
	else if (map)
		push(out, 'wps_cred_processing=1');

	v = pick_global(iface_data, data, 'wps_cred_add_sae');
	if (v != null && v != '')
		push(out, `wps_cred_add_sae=${v}`);
	else if (map)
		push(out, 'wps_cred_add_sae=1');

	/* MAP：忽略旧扫描结果 */
	v = pick_global(iface_data, data, 'ignore_old_scan_res');
	if (v != null && v != '')
		push(out, `ignore_old_scan_res=${v}`);
	else if (map)
		push(out, 'ignore_old_scan_res=1');

	/* PMF：UCI 优先；MAP 时 6g 强制 2，其它频段 1 */
	v = pick_global(iface_data, data, 'pmf');
	if (v != null && v != '') {
		push(out, `pmf=${v}`);
	} else if (map) {
		let band = normalize_band(data?.config?.band);
		push(out, `pmf=${band == '6g' ? 2 : 1}`);
	}

	/* autoscan：UCI 显式 0 表示关闭 */
	v = pick_global(iface_data, data, 'autoscan_interval');
	if (v == null)
		push(out, 'autoscan=periodic:30');
	else if (v != '' && v != '0' && v != 0)
		push(out, `autoscan=periodic:${v}`);

	/* sae_pwe 在 network 块内旧 wpad 不认，放到全局位置 */
	push(out, 'sae_pwe=2');

	return out;
};

function fixup_conf(text, iface_data, data) {
	let lines = split(trim(text ?? ''), '\n');
	let out = [];

	/* 顶部插入全局字段：for...in 遍历数组直接拿元素值 */
	for (let line in build_global(iface_data, data))
		push(out, line);

	for (let line in lines) {
		let drop = false;

		for (let re in GLOBAL_DEDUP)
			if (match(line, re)) { drop = true; break; }

		if (!drop)
			push(out, line);
	}

	return join('\n', out) + '\n';
}

/*
 * 找同一个 radio 上的 AP 接口名。setup() 的 data 里包含该 radio
 * 上所有接口，非 sta 的就是 AP。
 */
function find_ap_ifname(data) {
	let ks = keys(data.interfaces ?? {});

	for (let i = 0; i < length(ks); i++) {
		let iface_data = data.interfaces[ks[i]];
		let mode = iface_data?.config?.mode;

		if ((mode == 'ap' || mode == 'ap-wds') && !iface_data.config.disabled && iface_data.config.ifname)
			return iface_data.config.ifname;
	}

	return null;
};

/*
 * 等 AP 接口进入 operstate=up，最多等 tries * 0.2 秒。
 * netifd 触发 setup() 的时机几乎和 hostapd 启动同时，此时 phy 上的
 * AP BSS 还在半初始化，直接创建 STA 接口会被 MTK 驱动误处理，导致
 * AP 接口 MAC 归零、连带打坏整个 phy。
 */
function wait_ap_ready(data, tries) {
	let ap_ifname = find_ap_ifname(data);

	if (!ap_ifname)
		return true;

	for (let i = 0; i < tries; i++) {
		let state = trim(readfile(`/sys/class/net/${ap_ifname}/operstate`) ?? '');

		if (state == 'up')
			return true;
		/* MTK can leave operstate UNKNOWN while IFF_UP and carrier are set. */
		if (state == 'unknown' &&
		    (int(trim(readfile(`/sys/class/net/${ap_ifname}/flags`) ?? '0'), 16) & 1) &&
		    +trim(readfile(`/sys/class/net/${ap_ifname}/carrier`) ?? '0') == 1)
			return true;

		sleep(0.2);
	}

	log(`AP ${ap_ifname} not up after ${tries * 0.2}s`);
	return false;
};

/*
 * 让 MTK 驱动创建 STA 内核接口。
 *
 * 不用 wpa_supplicant 自己创建的原因：
 *   - 本仓库 wpad 不支持 interface_add 的 create 参数；
 *   - 即使不带 create，它也会把 iftype 选成 AP，phy 上已经有一个 AP BSS，
 *     MTK 驱动会以 -19 拒绝。
 */
function ensure_sta_iface(ifname, phy) {
	if (fs.stat(`/sys/class/net/${ifname}`))
		return true;

	if (!phy) {
		log(`no phy for ${ifname}, cannot create STA interface`);
		return false;
	}

	log(`creating STA interface ${ifname} on ${phy}`);
	system(`${IW} phy ${shell_quote(phy)} interface add ${shell_quote(ifname)} type station 2>/dev/null`);

	if (!wait_for(`/sys/class/net/${ifname}`, 30)) {
		log(`failed to create ${ifname} on ${phy}`);
		return false;
	}

	fs.writefile(`/var/run/mtwifi-created-${ifname}`, '1');
	return true;
};

/* 删内核 STA 接口。仅靠 wpa_cli interface_remove 只解除管理，
 * 内核接口不会消失，`iw dev` 里会残留。 */
function remove_sta_iface(ifname) {
	if (!fs.stat(`/var/run/mtwifi-created-${ifname}`))
		return true;
	if (!fs.stat(`/sys/class/net/${ifname}`)) {
		fs.unlink(`/var/run/mtwifi-created-${ifname}`);
		return true;
	}

	/* 从任何网桥里摘掉 apcli */
	if (fs.stat(`/sys/class/net/${ifname}/master`))
		system(`ip link set ${shell_quote(ifname)} nomaster 2>/dev/null`);

	system(`ip link set ${shell_quote(ifname)} down 2>/dev/null`);
	system(`${IW} dev ${shell_quote(ifname)} del 2>/dev/null`);

	for (let i = 0; i < 30 && fs.stat(`/sys/class/net/${ifname}`); i++)
		sleep(0.1);
	let removed = !fs.stat(`/sys/class/net/${ifname}`);
	if (removed)
		fs.unlink(`/var/run/mtwifi-created-${ifname}`);
	return removed;
};

/* Prepare all STA credentials before changing .dat or attaching any interface. */
export function prepare(data) {
	let entries = [];
	let staged = capture_files(() => {
		for (let k in sort(keys(data.interfaces ?? {}))) {
			let vif = data.interfaces[k];
			if (vif?.config?.mode != 'sta' || vif.config.disabled)
				continue;
			/* The vendor APCLI datapath handles the MTK bridge integration. */
			let entry = supplicant.generate([], data, { ...vif, bridge: null }, true);
			if (type(entry) != 'object')
				return false;
			entry.text = fixup_conf(entry.text, vif, data);
			entry.previous = readfile(entry.config);
			entry.vif = vif;
			if (!daemon_config_write(entry.config, entry.text, WPA_CTRL_DIR))
				return false;
			push(entries, entry);
		}
		return length(entries) > 0;
	});
	return { ok: staged.result, entries, files: staged.files, data, touched: [] };
};

export function wait_ready() {
	for (let i = 0; i < 50; i++) {
		if (fs.stat(`${WPA_CTRL_DIR}/global`) && length(global.ubus.list('wpa_supplicant')))
			return true;
		sleep(0.1);
	}
	return false;
};

function attach(entry) {
	let reply = global.ubus.call('wpa_supplicant', 'config_add', {
		iface: entry.iface, config: entry.config,
		driver: 'nl80211', ctrl: WPA_CTRL_DIR,
	});
	if (type(reply) != 'object' || !(reply.pid > 1))
		return false;
	netifd.add_process('/usr/sbin/wpa_supplicant', reply.pid, true, true);
	return true;
};

function detach(ifname) {
	global.ubus.call('wpa_supplicant', 'config_remove', { iface: ifname });
	return global.ubus.error() == null;
};

export function activate(plan) {
	if (!plan.ok || !wait_for(`${WPA_CTRL_DIR}/global`, 30))
		return false;
	if (!wait_ap_ready(plan.data, 150) || !commit_files(plan))
		return false;

	let phy = plan.data.phy;
	for (let entry in plan.entries) {
		let ifname = entry.iface;
		let state = {
			entry, was_attached: index(iface_list(), ifname) >= 0,
			created: !fs.stat(`/sys/class/net/${ifname}`),
			mac: trim(readfile(`/sys/class/net/${ifname}/address`) ?? ''),
		};
		push(plan.touched, state);
		if (!ensure_sta_iface(ifname, phy))
			return false;

		if (state.was_attached && !detach(ifname))
			return false;
		state.detached = true;
		let cfg = entry.vif.config;
		if (!cfg.default_macaddr && cfg.macaddr) {
			if (system(`ip link set ${shell_quote(ifname)} down`) ||
			    system(`ip link set ${shell_quote(ifname)} address ${shell_quote(cfg.macaddr)}`))
				return false;
			state.mac_changed = true;
		}
		if (!attach(entry)) {
			log(`interface_add ${ifname} failed`);
			return false;
		}
		if (system(`ip link set ${shell_quote(ifname)} up`))
			return false;
		scan_action_start(ifname);
	}
	return true;
};

export function stop(plan) {
	let ok = true;
	for (let state in reverse(plan?.touched ?? [])) {
		let ifname = state.entry.iface;
		scan_action_stop(ifname);
		if (state.detached && index(iface_list(), ifname) >= 0 && !detach(ifname)) {
			ok = false;
			continue;
		}
		if (state.created)
			ok = remove_sta_iface(ifname) && ok;
		else if (state.mac_changed && length(state.mac)) {
			ok = !system(`ip link set ${shell_quote(ifname)} down`) && ok;
			ok = !system(`ip link set ${shell_quote(ifname)} address ${shell_quote(state.mac)}`) && ok;
		}
	}
	return ok;
};

export function rollback(plan, restart) {
	if (!plan)
		return true;
	if (!rollback_files(plan))
		return false;
	let ok = true;
	for (let state in plan.touched) {
		let entry = state.entry;
		if (restart == false || !state.detached || !state.was_attached)
			continue;
		if (entry.previous == null || !attach(entry)) {
			ok = false;
			continue;
		}
		ok = !system(`ip link set ${shell_quote(entry.iface)} up`) && ok;
		scan_action_start(entry.iface);
	}
	plan.touched = [];
	return ok;
};

/*
 * 清掉属于该 radio 的 apcli 接口（按 L1 profile 的 apcli 前缀匹配）。
 */
export function teardown(apcli_prefix) {
	if (!apcli_prefix)
		return true;

	/* 合并 wpa_supplicant 已知的 + 内核里存在的 apcli 接口 */
	let targets = {};

	for (let ifname in iface_list())
		if (substr(ifname, 0, length(apcli_prefix)) == apcli_prefix &&
		    match(substr(ifname, length(apcli_prefix)), /^[0-9]+$/))
			targets[ifname] = true;

	for (let p in fs.glob(`/sys/class/net/${apcli_prefix}*`)) {
		let ifname = fs.basename(p);

		/* 只取 <prefix><digits>，避免 apcli 前缀误伤 apclii0 */
		if (substr(ifname, 0, length(apcli_prefix)) != apcli_prefix)
			continue;
		if (!match(substr(ifname, length(apcli_prefix)), /^[0-9]+$/))
			continue;

		targets[ifname] = true;
	}

	let ok = true;
	/* 遍历 object 的键，ucode 里 for...in 对 object 给键名 */
	for (let ifname in targets) {
		log(`teardown: cleaning ${ifname}`);

		scan_action_stop(ifname);

		if ((index(iface_list(), ifname) >= 0 && !detach(ifname)) ||
		    !remove_sta_iface(ifname)) {
			ok = false;
			continue;
		}

		fs.unlink(`/var/run/wpa-supplicant-${ifname}.conf`);
		fs.unlink(`/var/run/scan_state-${ifname}`);
		fs.unlink(`${WPA_CTRL_DIR}/wpa_supplicant-${ifname}.conf`);
	}
	return ok;
};

export { iface_cli, global_cli, iface_list };

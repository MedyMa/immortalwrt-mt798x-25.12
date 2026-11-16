#!/usr/bin/env ucode
'use strict';

// SPDX-License-Identifier: GPL-2.0
/*
 * mtwifi UCI config generator ("wifi config" detection)
 *
 * Copyright (C) 2024 OpenWrt.org
 * Copyright (C) 2026 nanchuci <nanchuci023@gmail.com>
 *
 * 取代旧的 /lib/wifi/mtwifi.sh:detect_mtwifi()（shell + l1util 子进程）。
 * 由 /sbin/wifi config 通过 detect_mtwifi() 调用：
 *
 *     ucode /lib/wifi/mtwifi.uc | uci -q batch
 *
 * 命名与官方 wifi-scripts/lib/wifi/mac80211.uc 保持一致：
 *   - wifi-device 段为 radio0/radio1/...
 *   - 每个段带 type=mtwifi、phy=、band=、channel=、htmode=、country=
 *   - 额外写入 MTK 私有的 devname=（L1 profile 里的 INDEX_mainidx[_subidx]）
 *
 * 同时按官方 wifi-detect.uc 的风格补全 /etc/board.json 的 wlan 条目
 * （只补缺失的，不覆盖已存在的；官方 wifi-detect.uc 每次 wifi config
 * 都会重写 wlan.phy* 条目，所以这里写的只是兜底）。
 *
 * 已存在的 wifi-device 段（不论段名是不是 radioN，只要 type=mtwifi 且
 * 指向同一个 devname）不会被改动，重复执行是幂等的。
 */

import * as fs from 'fs';
import * as uci from 'uci';
import * as l1dat from 'mtwifi.l1dat';
import { trim, log, shell_quote } from 'mtwifi.common';

const BOARD_FILE = '/etc/board.json';
const L1_DAT_PATH = l1dat.L1_DAT_PATH;

/* 旧 detect 脚本的默认值（band -> htmode / 频点 / SSID / noscan） */
const BAND_DEFAULTS = {
	'2g': { htmode: 'EHT40', channel: 'auto', ssid: 'ImmortalWrt-2.4G', noscan: '1',  },
	'5g': { htmode: 'EHT160', channel: '36', ssid: 'ImmortalWrt-5G', noscan: '0',  },
	'6g': { htmode: 'EHT320', channel: '37', ssid: 'ImmortalWrt-6G', noscan: '0',  },
};

function phy_of_ifname(ifname) {
	if (!ifname)
		return null;

	let link = fs.readlink(`/sys/class/net/${ifname}/phy80211`);

	if (link)
		return fs.basename(link);

	let name = trim(fs.readfile(`/sys/class/net/${ifname}/phy80211/name`) ?? '');

	return length(name) ? name : null;
};

function phy_index(phy) {
	return +trim(fs.readfile(`/sys/class/ieee80211/${phy}/index`) ?? '0');
};

/* 与官方 wifi-detect.uc 的 phy_path() 一致 */
function phy_path(phy) {
	let devpath = fs.realpath(`/sys/class/ieee80211/${phy}/device`);

	if (!devpath)
		return null;

	devpath = replace(devpath, /^\/sys\/devices\//, '');
	if (match(devpath, /^platform\/.*\/pci/))
		devpath = replace(devpath, /^platform\//, '');

	let dev_phys = map(fs.glob(`/sys/class/ieee80211/${phy}/device/ieee80211/*`), fs.basename);
	sort(dev_phys, (a, b) => phy_index(a) - phy_index(b));

	let ofs = index(dev_phys, phy);
	if (ofs > 0)
		devpath += `+${ofs}`;

	return devpath;
};

function band_of(dev) {
	if (dev.band != null && length(trim(dev.band)))
		return lc(trim(dev.band));

	let base = dev.main_ifname ?? dev.ext_ifname ?? '';
	if (substr(base, 0, 3) == 'rax') return '6g';
	if (substr(base, 0, 3) == 'rai') return '5g';
	if (substr(base, 0, 2) == 'ra')  return '2g';

	return (dev.subidx ?? 1) == 1 ? '2g' : '5g';
};

/*
 * 生成 ifname 后缀递增：ra0 + 0 → ra0；ra0 + 1 → ra1。
 * PDF 没有规定多 BSS 的命名，但物理名必须唯一且由 L1 根名派生。
 */
function existing_devices(config) {
	let by_devname = {};
	let names = {};

	for (let name, section in config) {
		if (section['.type'] != 'wifi-device')
			continue;

		names[name] = true;

		/*
		 * 新配置用 devname 选项；旧配置（段名就是 devname）通过
		 * “段名出现在 L1 profile 里”来识别。
		 */
		if (section.devname)
			by_devname[section.devname] = name;
		else if (section.type == 'mtwifi')
			by_devname[name] = name;
	}

	return { by_devname, names };
};

function main() {
	let l1 = l1dat.load(L1_DAT_PATH);
	if (!l1)
		return 0;
	let config = uci.cursor().get_all('wireless') ?? {};
	let existing = existing_devices(config);
	let board = json(fs.readfile(BOARD_FILE) ?? '{}') ?? {};
	let idx = 0;
	let out = [];
	function set(name, key, value) {
		push(out, `set wireless.${name}.${key}=${shell_quote(value)}`);
	};
	for (let devname in l1dat.list(l1)) {
		if (!match(devname, /^[a-zA-Z0-9_]+$/))
			continue;
		let dev = l1[l1dat.DEV_RINDEX][devname];
		if (!dev)
			continue;
		let phy = phy_of_ifname(dev.main_ifname);
		let name = existing.by_devname[devname];
		if (name) {
			/* Upgrade metadata only. SSID, keys, encryption, channel and width stay intact. */
			if (!config[name].devname)
				set(name, 'devname', devname);
			if (phy && !config[name].phy)
				set(name, 'phy', phy);
			let path = phy ? phy_path(phy) : null;
			if (path && !config[name].path)
				set(name, 'path', path);
			continue;
		}
		if (!phy) {
			log(`no cfg80211 phy for ${devname}; deferring detection`);
			continue;
		}
		while (config[`radio${idx}`] || config[`default_radio${idx}`])
			idx++;
		name = `radio${idx}`;
		let iface = `default_${name}`;
		let band = band_of(dev);
		let defaults = BAND_DEFAULTS[band];
		if (!defaults)
			continue;
		let path = phy_path(phy);
		push(out, `set wireless.${name}=wifi-device`);
		for (let key, value in { type: 'mtwifi', devname, phy, band,
			channel: defaults.channel, htmode: defaults.htmode,
			dbdc_main: (dev.subidx ?? 1) == 1 ? '1' : '0',
			disabled: '1' })
			set(name, key, value);
		if (path)
			set(name, 'path', path);
		let country = board.wlan?.defaults?.country ?? '00';
		set(name, 'country', match(country, /^([A-Z]{2}|00)$/) ? country : '00');
		push(out, `set wireless.${iface}=wifi-iface`);
		for (let key, value in { device: name, network: 'lan',
			ifname: dev.main_ifname, mode: 'ap', ssid: defaults.ssid,
			encryption: band == '6g' ? 'owe' : 'none',
			ieee80211w: band == '6g' ? '2' : '0' })
			set(iface, key, value);
		config[name] = {};
		config[iface] = {};
		idx++;
	}
	if (length(out)) {
		push(out, 'commit wireless');
		printf('%s\n', join('\n', out));
	}
	return 0;
};

exit(main());

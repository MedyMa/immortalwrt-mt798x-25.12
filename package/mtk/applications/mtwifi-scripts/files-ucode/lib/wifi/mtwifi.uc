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
 * 板级能力由通用 wifi-detect.uc 探测，本脚本只补全 UCI 设备元数据。
 * 新设备用 L1 名称，已存在的段保留名称和接口引用。
 */

import * as fs from 'fs';
import * as uci from 'uci';
import * as l1dat from 'mtwifi.l1dat';
import { load_profile } from 'mtwifi.dat';
import defs from 'mtwifi.defs';
import { trim, log, shell_quote } from 'mtwifi.common';
import { normalize_legacy_device } from 'mtwifi.validate';

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
	return l1dat.device_band(dev);
};

function existing_devices(config) {
	let by_devname = {};

	for (let name, section in config) {
		if (section['.type'] != 'wifi-device' || section.type != 'mtwifi')
			continue;
		by_devname[section.devname || name] = name;
	}

	return by_devname;
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
		let name = existing[devname];
		if (name) {
			let normalized = { ...config[name] };
			normalize_legacy_device(normalized, dev);
			for (let key in [ 'band', 'htmode', 'channel' ])
				if (normalized[key] != null && normalized[key] != config[name][key])
					set(name, key, normalized[key]);
			if (!config[name].devname)
				set(name, 'devname', devname);
			if (phy && (!config[name].phy || config[name].phy == dev.main_ifname))
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
		name = devname;
		if (config[name] || config[`default_${name}`]) {
			while (config[`radio${idx}`] || config[`default_radio${idx}`])
				idx++;
			name = `radio${idx++}`;
		}
		let iface = `default_${name}`;
		let band = band_of(dev);
		let defaults = BAND_DEFAULTS[band];
		if (!defaults)
			continue;
		let path = phy_path(phy);
		push(out, `set wireless.${name}=wifi-device`);
		for (let key, value in { type: 'mtwifi', devname, phy, band,
			channel: defaults.channel, htmode: defaults.htmode, noscan: defaults.noscan,
			dbdc_main: (dev.subidx ?? 1) == 1 ? '1' : '0' })
			set(name, key, value);
		if (path)
			set(name, 'path', path);
		let country = board.wlan?.defaults?.country;
		if (country == null && dev.profile_path)
			country = load_profile(dev.profile_path)?.CountryCode;
		set(name, 'country', defs.countryRegions[country ?? ''] ? country : '00');
		push(out, `set wireless.${iface}=wifi-iface`);
		for (let key, value in { device: name, network: 'lan',
			ifname: dev.main_ifname, mode: 'ap', ssid: defaults.ssid,
			encryption: band == '6g' ? 'owe' : 'none',
			ieee80211w: band == '6g' ? '2' : '0' })
			set(iface, key, value);
		config[name] = {};
		config[iface] = {};
	}
	if (length(out)) {
		push(out, 'commit wireless');
		printf('%s\n', join('\n', out));
	}
	return 0;
};

exit(main());

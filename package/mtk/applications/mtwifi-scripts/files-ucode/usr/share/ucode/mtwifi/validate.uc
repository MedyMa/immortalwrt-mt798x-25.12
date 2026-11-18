// SPDX-License-Identifier: GPL-2.0
'use strict';
import * as fs from 'fs';
import { trim, valid_ifname } from 'mtwifi.common';
import * as uci from 'uci';
import { device_band } from 'mtwifi.l1dat';
import defs from 'mtwifi.defs';

export function normalize_legacy_device(config, dev) {
	let defaults = {
		'2g': { htmode: 'EHT40', channel: 'auto' },
		'5g': { htmode: 'EHT160', channel: '36' },
		'6g': { htmode: 'EHT320', channel: '37' },
	};
	let band = device_band(dev);
	let missing_band = config.band == null || config.band == '';
	let legacy = missing_band && config.phy == dev?.main_ifname;
	if ((missing_band || config.band == 'auto') && band)
		config.band = band;
	if (!defaults[config.band]) return;
	if ((dev?.band || dev?.INDEX == 'MT7990') && band && band != config.band)
		die('PHY_PROFILE_MISMATCH');
	if (config.htmode == null || config.htmode == '' || (legacy && config.htmode == 'NOHT'))
		config.htmode = defaults[config.band].htmode;
	if (config.channel === 0 || config.channel === '0')
		config.channel = 'auto';
	else if (config.channel == null || config.channel === '')
		config.channel = defaults[config.band].channel;
};

function limits(config, ranges) {
	for (let key, range in ranges) {
		let value = config[key];
		if (value != null && (+value != int(value) || +value < range[0] || +value > range[1]))
			die('INVALID_VENDOR_OPTION_' + key);
	}
};

function validate_mlo(data, previous) {
	let config = previous ?? uci.cursor().get_all('wireless') ?? {};
	let affected = {};
	for (let index, iface in data.interfaces ?? {}) {
		let name = iface.name ?? index;
		for (let c in [ config[name] ?? {}, iface.config ]) {
			let group = c.mldgroup ?? (+c.mlo ? 1 : 0);
			if (+group) affected[group] = true;
		}
		config[name] = { ...(config[name] ?? {}), ...iface.config };
		let device = config[name].device;
		if (device && config[device])
			config[device] = { ...config[device], ...data.config };
	}
	let groups = {};
	for (let name, iface in config) {
		let dev = config[iface.device];
		if (iface.mode != 'ap' || dev?.type != 'mtwifi' || +iface.disabled || +dev.disabled)
			continue;
		let group = iface.mldgroup ?? (+iface.mlo ? 1 : 0);
		if (!+group || !affected[group]) continue;
		/* BE14's profile parser enables MLO only for group 1. */
		if (+group != 1 || !match(dev.htmode ?? '', /^EHT/) || +iface.wds || +iface.mwds)
			die('INVALID_MLO_MEMBER');
		let enc = iface.encryption ?? 'none';
		if (!match(enc, /^(sae|owe)(\+|$)/) ||
		    (iface.ieee80211w != null && +iface.ieee80211w != 2))
			die('MLO_REQUIRES_WPA3_AND_PMF');
		let signature = [];
		let encryption = split(enc, '+');
		let cipher = encryption[1] ?? (encryption[0] == 'sae' &&
			(iface.gcmp256 == null || iface.gcmp256 === true || +iface.gcmp256 == 1)
			? 'ccmp+gcmp256' : 'ccmp');
		push(signature, encryption[0], cipher);
		push(signature, '' + (iface.sae_pwe ?? 2));
		for (let key in [ 'ssid', 'key', 'mobility_domain' ])
			push(signature, '' + (iface[key] ?? ''));
		for (let key in [ 'sae_ext_key', 'ieee80211r' ]) {
			let value = iface[key] ?? (key != 'ieee80211r' && encryption[0] == 'sae');
			push(signature, value === true || +value == 1 ? '1' : '0');
		}
		push(signature, iface.ft_over_ds === true || +iface.ft_over_ds == 1 ? '1' : '0');
		let networks = type(iface.network) == 'array' ? iface.network : split(iface.network ?? '', /\s+/);
		push(signature, join(' ', sort(networks)));
		let value = sprintf('%J', signature);
		groups[group] ??= { signature: value, devices: {}, count: 0 };
		let members = groups[group];
		if (members.signature != value || members.devices[iface.device])
			die('MLO_SETTINGS_MISMATCH');
		members.devices[iface.device] = true;
		members.count++;
	}
	for (let _, group in groups)
		if (group.count < 2 || group.count > 3)
			die('INVALID_MLO_MEMBER_COUNT');
};

function check_text(value) {
	if (type(value) == 'string' && (match(value, /[\r\n]/) || index(value, '\0') >= 0))
		die('PROFILE_CONTROL_CHARACTER');
	if (type(value) == 'array' || type(value) == 'object')
		for (let key, item in value)
			check_text(item);
};

function feature_defaults(data) {
	let config = data.config;
	let he = !!match(config.htmode ?? '', /^(HE|EHT)/);
	let eht = !!match(config.htmode ?? '', /^EHT/);
	config.tx_burst ??= true;
	if (match(config.htmode ?? '', /^(VHT|HE|EHT)/))
		config.mu_beamformer ??= true;
	if (he) {
		config.he_ldpc ??= true;
		config.twt ??= 3;
	}
	if (eht)
		config.eht_restricted_twt ??= true;
	for (let _, iface in data.interfaces ?? {}) {
		let c = iface.config;
		if (c?.mode != 'ap') continue;
		for (let key in [ 'amsdu', 'autoba', 'uapsd' ])
			c[key] ??= true;
		if (he)
			for (let key in [ 'mumimo_dl', 'mumimo_ul', 'ofdma_dl', 'ofdma_ul' ])
				c[key] ??= true;
		if (eht && match(c.encryption ?? '', /^sae(-mixed)?(\+|$)/)) {
			c.gcmp256 ??= true;
			c.sae_ext_key ??= true;
		}
	}
};

export function center80(band, channel) {
	if (!match('' + channel, /^[0-9]+$/)) return null;
	channel = +channel;
	if (band == '6g' && channel >= 1 && channel <= 221 && channel % 4 == 1)
		return 7 + 16 * int((channel - 1) / 16);
	if (band == '5g')
		for (let center in [ 42, 58, 106, 122, 138, 155, 171 ])
			if (channel >= center - 6 && channel <= center + 6 && (channel - center + 6) % 4 == 0)
				return center;
	return null;
};

export function segments80(config) {
	let first = center80(config.band, config.channel);
	let second = center80(config.band, config.channel2);
	if (first == null || second == null || (first - second <= 16 && second - first <= 16))
		die('INVALID_80P80_CHANNELS');
	return [ first, second ];
};

export function center320(channel, layout) {
	channel = +channel;
	if (channel < 1 || channel % 4 != 1)
		return null;
	for (let center in layout ? [ 31, 63, 95, 127, 159, 191 ] : [ 31, 95, 159, 191 ])
		if ((!layout || (int((center - 31) / 32) % 2 + 1) == layout) &&
		    channel >= center - 30 && channel <= center + 30)
			return center;
	return null;
};

function normalize_acl(config) {
	if (!(config.macfilter in [ 'allow', 'deny' ]))
		return;
	let list = config.maclist ?? [];
	if (type(list) != 'array') die('INVALID_MAC_ACL');
	if (config.macfile) {
		let info = fs.stat(config.macfile);
		if (info?.type != 'file' || info.size > 16384) die('INVALID_MAC_ACL');
		let file = fs.open(config.macfile, 're');
		if (!file) die('INVALID_MAC_ACL');
		let content = file.read(16385);
		file.close();
		if (length(content) > 16384) die('INVALID_MAC_ACL');
		list = [ ...list, ...split(content ?? '', '\n') ];
	}
	let entries = {};
	for (let raw in list) {
		let line = trim(split(raw, '#', 2)[0]);
		if (!length(line)) continue;
		let m = match(line, /^(([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})([ \t]+([0-9]{1,4}))?$/);
		if (!m || (m[4] && (+m[4] < 1 || +m[4] > 4094)))
			die('INVALID_MAC_ACL');
		let mac = lc(m[1]);
		let entry = m[4] ? mac + ' ' + +m[4] : mac;
		if (entries[mac] && entries[mac] != entry) die('INVALID_MAC_ACL');
		entries[mac] = entry;
	}
	if (length(keys(entries)) > defs.max_acl_entry) die('MAC_ACL_TOO_LARGE');
	config.maclist = map(keys(entries), (mac) => entries[mac]);
	delete config.macfile;
};

export function validate_profile(data, previous) {
	check_text(data);
	let config = data.config;
	if (config.channel === 0 || config.channel === '0')
		config.channel = 'auto';
	limits(config, { twt: [0, 3], tx_preamble: [0, 2], txpower: [1, 100],
		beacon_int: [20, 999], eht_bw320_offset: [0, 2] });
	if (config.channel == 'auto')
		limits(config, { acs_alg: [1, 3] });
	if (!(config.band in [ '2g', '5g', '6g' ]))
		die('INVALID_BAND');
	if (config.band == '6g' && +(config.he_6ghz_reg_pwr_type ?? 0) != 0)
		die('SIX_GHZ_POWER_TYPE_NOT_SUPPORTED');
	if (config.band == '6g' && config.channel == 'auto' && config.psc_acs && config.acs_alg == 1)
		die('ACS_PSC_REQUIRES_BUSY_TIME');
	let bw = match(config.htmode ?? '', /^(HT|VHT|HE|EHT)(20|40|80_80|80|160|320)([+-]|-[12])?$/);
	let split = bw?.[2] == '80_80';
	if ((!bw && config.htmode != 'NOHT') ||
	    (split && (!(bw[1] in [ 'VHT', 'HE' ]) || config.band == '2g' || bw[3])) ||
	    (config.htmode == 'NOHT' && config.band == '6g') ||
	    (bw?.[1] == 'VHT' && config.band != '5g') ||
	    (bw?.[1] == 'HT' && +bw?.[2] > 40) ||
	    (bw?.[3] && !(+bw[2] == 40 && bw[3] in [ '+', '-' ]) &&
	        !(bw[1] == 'EHT' && +bw[2] == 320 && bw[3] in [ '-1', '-2' ])) ||
	    (config.band == '2g' && +bw?.[2] > 40) ||
	    (config.band != '6g' && +bw?.[2] > 160) ||
	    (config.band == '6g' && !(bw?.[1] in [ 'HE', 'EHT' ])) ||
	    (+bw?.[2] == 320 && bw?.[1] != 'EHT'))
		die('INVALID_BANDWIDTH');
	if (split) segments80(config);
	let required = { n: 1, ac: 2, ax: 3, be: 4 }[config.require_mode];
	let selected = { HT: 1, VHT: 2, HE: 3, EHT: 4 }[bw?.[1]] ?? 0;
	if (required != null && (required > selected || (config.require_mode == 'ac' && config.band != '5g')))
		die('INVALID_REQUIRED_MODE');
	let country = config.country_code ?? config.country;
	if (country != null && !match(country, /^([A-Z]{2}|00)$/))
		die('INVALID_COUNTRY');
	let channel = config.channel;
	if (channel != null && channel != 'auto' &&
	    (!match('' + channel, /^[0-9]+$/) || +channel > { '2g': 14, '5g': 196, '6g': 233 }[config.band]))
		die('INVALID_CHANNEL');
	if (+bw?.[2] == 320 && channel != 'auto' &&
	    center320(channel, +(bw?.[3] ? substr(bw[3], 1) : 0)) == null)
		die('INVALID_CHANNEL');
	feature_defaults(data);
	let ap_count = 0;
	let sta_count = 0;
	for (let key, iface in data.interfaces ?? {}) {
		let c = iface.config;
		if (type(c) != 'object')
			die('INVALID_INTERFACE');
		check_text(c);
		limits(c, { mldgroup: [0, 1], ieee80211w: [0, 2], frag: [256, 2346], rts: [0, 2347],
			kicklow: [-100, 0], assocthres: [-100, 0] });
		if (!(c.mode in [ 'ap', 'sta' ]))
			die('UNSUPPORTED_MODE');
		if (+c.mwds && (+c.wds || +c.mlo || +c.mldgroup || +c.mac_repeater))
			die('INVALID_MWDS_MODE');
		if (!valid_ifname(c.ifname))
			die('INVALID_IFNAME');
		for (let value in [ c.macaddr, c.bssid ])
			if (value != null && value != '' &&
			    (!match(value, /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/) ||
			     (int(substr(value, 0, 2), 16) & 1) || value == '00:00:00:00:00:00'))
				die('INVALID_MAC_ADDRESS');
		if (c.mode == 'ap') ap_count++;
		else sta_count++;
		let enrolling = c.mode == 'sta' && c.encryption == 'wps' && config.band != '6g';
		if ((!enrolling && !length(c.ssid ?? '')) || length(c.ssid) > 32)
			die('INVALID_SSID');
		if (c.mode == 'ap') normalize_acl(c);
		let enc = c.encryption ?? 'none';
		if (match(enc, /^(sae|owe)(\+|$)/)) {
			if (c.ieee80211w != null && +c.ieee80211w != 2)
				die('WPA3_REQUIRES_PMF');
			c.ieee80211w = 2;
		}
		if (config.band == '6g') {
			if (!(enc in [ 'sae', 'sae+ccmp', 'sae+gcmp', 'sae+gcmp256', 'owe', 'owe+ccmp', 'wpa3', 'wpa3+ccmp', 'wpa3-192' ]) ||
			    (c.ieee80211w != null && +c.ieee80211w != 2))
				die('SIX_GHZ_REQUIRES_WPA3_AND_PMF');
			c.ieee80211w = 2;
			c.wps_pushbutton = false;
			c.wps_label = false;
			c.ext_registrar = false;
		}
		for (let _, vlan in iface.vlans ?? {}) {
			let v = vlan.config;
			if (v?.name && !valid_ifname(c.ifname + '-' + v.name))
				die('INVALID_VLAN_IFNAME');
			if (v?.vid && (!match('' + v.vid, /^[0-9]+$/) || +v.vid < 1 || +v.vid > 4094))
				die('INVALID_VLAN_ID');
		}
		for (let _, sta in iface.stas ?? {}) {
			let v = sta.config;
			for (let mac in v?.mac ?? [])
				if (!match(mac, /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/))
					die('INVALID_STATION_MAC');
			if (v?.vid && (!match('' + v.vid, /^[0-9]+$/) || +v.vid < 1 || +v.vid > 4094))
				die('INVALID_VLAN_ID');
			if (v?.key && match(enc, /^(psk|sae)/)) {
				let psk = substr(enc, 0, 3) == 'psk';
				if ((psk && length(v.key) < 8) ||
				    (length(v.key) > 63 && !(psk && match(v.key, /^[0-9a-fA-F]{64}$/))) ||
				    (!psk && index(v.key, '|') >= 0))
					die('INVALID_STATION_PASSPHRASE');
			}
		}
		if (match(enc, /^(psk|sae)/)) {
			let key = c.key ?? '';
			if (!length(key) || (substr(enc, 0, 3) == 'psk' && length(key) < 8) ||
			    (length(key) > 63 && !(substr(enc, 0, 3) == 'psk' && match(key, /^[0-9a-fA-F]{64}$/))))
				die('INVALID_PASSPHRASE');
		}
	}
	if (ap_count > 16 || sta_count > 1 || ap_count + sta_count == 0)
		die('INVALID_VIF_COUNT');
	validate_mlo(data, previous);
};

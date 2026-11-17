// SPDX-License-Identifier: GPL-2.0
'use strict';
import { valid_ifname } from 'mtwifi.common';
import * as uci from 'uci';
import { device_band } from 'mtwifi.l1dat';

export function normalize_legacy_device(config, dev) {
	let defaults = {
		'2g': { htmode: 'EHT40', channel: 'auto' },
		'5g': { htmode: 'EHT160', channel: '36' },
		'6g': { htmode: 'EHT320', channel: '37' },
	};
	let band = device_band(dev);
	let missing_band = config.band == null || config.band == '';
	let legacy = missing_band && config.phy == dev?.main_ifname;
	if (missing_band && band) config.band = band;
	if (!defaults[config.band]) return;
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
		if (+group != 1 || !match(dev.htmode ?? '', /^EHT/) || +iface.wds)
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

export function validate_profile(data, previous) {
	check_text(data);
	let config = data.config;
	limits(config, { twt: [0, 3], tx_preamble: [0, 2], txpower: [1, 100],
		beacon_int: [20, 999], eht_bw320_offset: [0, 1] });
	if (!(config.band in [ '2g', '5g', '6g' ]))
		die('INVALID_BAND');
	let bw = match(config.htmode ?? '', /^(HT|VHT|HE|EHT)(20|40|80|160|320)([+-]|-[12])?$/);
	if ((!bw && config.htmode != 'NOHT') ||
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
		if (!valid_ifname(c.ifname))
			die('INVALID_IFNAME');
		for (let value in [ c.macaddr, c.bssid ])
			if (value != null && value != '' &&
			    (!match(value, /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/) ||
			     (int(substr(value, 0, 2), 16) & 1) || value == '00:00:00:00:00:00'))
				die('INVALID_MAC_ADDRESS');
		if (c.mode == 'ap') ap_count++;
		else sta_count++;
		if (!length(c.ssid ?? '') || length(c.ssid) > 32)
			die('INVALID_SSID');
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

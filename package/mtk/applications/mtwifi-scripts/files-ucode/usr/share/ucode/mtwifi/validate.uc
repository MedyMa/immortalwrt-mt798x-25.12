// SPDX-License-Identifier: GPL-2.0
'use strict';
import { valid_ifname } from 'mtwifi.common';

function check_text(value) {
	if (type(value) == 'string' && (match(value, /[\r\n]/) || index(value, '\0') >= 0))
		die('PROFILE_CONTROL_CHARACTER');
	if (type(value) == 'array' || type(value) == 'object')
		for (let key, item in value)
			check_text(item);
};

export function validate_profile(data) {
	check_text(data);
	let config = data.config;
	if (!(config.band in [ '2g', '5g', '6g' ]))
		die('INVALID_BAND');
	let bw = match(config.htmode ?? '', /^(HT|VHT|HE|EHT)(20|40|80|160|320)([+-]|-[12])?$/);
	if ((!bw && config.htmode != 'NOHT') ||
	    (config.htmode == 'NOHT' && config.band == '6g') ||
	    (config.band == '2g' && +bw?.[2] > 40) ||
	    (config.band != '6g' && +bw?.[2] > 160) ||
	    (config.band == '6g' && !(bw?.[1] in [ 'HE', 'EHT' ])) ||
	    (+bw?.[2] == 320 && bw?.[1] != 'EHT'))
		die('INVALID_BANDWIDTH');
	let country = config.country_code ?? config.country;
	if (country != null && !match(country, /^([A-Z]{2}|00)$/))
		die('INVALID_COUNTRY');
	let channel = config.channel;
	if (channel != null && channel != 'auto' &&
	    (!match('' + channel, /^[0-9]+$/) || +channel > 233))
		die('INVALID_CHANNEL');
	let ap_count = 0;
	let sta_count = 0;
	for (let key, iface in data.interfaces ?? {}) {
		let c = iface.config;
		if (type(c) != 'object')
			die('INVALID_INTERFACE');
		check_text(c);
		if (!(c.mode in [ 'ap', 'sta' ]))
			die('UNSUPPORTED_MODE');
		if (!valid_ifname(c.ifname))
			die('INVALID_IFNAME');
		if (c.mode == 'ap') ap_count++;
		else sta_count++;
		if (!length(c.ssid ?? '') || length(c.ssid) > 32)
			die('INVALID_SSID');
		let enc = c.encryption ?? 'none';
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
};

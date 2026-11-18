#!/usr/bin/env ucode
// SPDX-License-Identifier: GPL-2.0
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';
import * as ubus from 'ubus';
import { valid_ifname, log } from 'mtwifi.common';

const ATTR_CREDENTIAL = 0x100e;
const ATTR_SSID = 0x1045;
const ATTR_AUTH_TYPE = 0x1003;
const ATTR_ENCR_TYPE = 0x100f;
const ATTR_NETWORK_KEY = 0x1027;

function read_attributes(bytes) {
	let attrs = {};
	for (let i = 0; i < length(bytes);) {
		if (length(bytes) - i < 4) return null;
		let id = (ord(bytes, i) << 8) | ord(bytes, i + 1);
		let len = (ord(bytes, i + 2) << 8) | ord(bytes, i + 3);
		i += 4;
		if (len > length(bytes) - i) return null;
		if (id in [ ATTR_CREDENTIAL, ATTR_SSID, ATTR_AUTH_TYPE, ATTR_ENCR_TYPE, ATTR_NETWORK_KEY ]) {
			if (attrs[id] != null) return null;
			attrs[id] = substr(bytes, i, len);
		}
		i += len;
	}
	return attrs;
};

function credential(hex) {
	if (length(hex) > 2048 || !match(hex, /^([0-9A-Fa-f]{2})+$/)) return null;
	let attrs = read_attributes(hexdec(hex));
	/* Hostapd emits wrapped credentials and unwrapped AP Settings. */
	let data = attrs?.[ATTR_CREDENTIAL] != null ? read_attributes(attrs[ATTR_CREDENTIAL]) : attrs;
	let ssid = data?.[ATTR_SSID];
	let key = data?.[ATTR_NETWORK_KEY] ?? '';
	let auth = data?.[ATTR_AUTH_TYPE];
	let cipher = data?.[ATTR_ENCR_TYPE];
	if (!length(ssid) || length(ssid) > 32 || length(auth) != 2 || length(cipher) != 2 ||
	    match(ssid + key, /[\r\n]/) || index(ssid + key, '\0') >= 0)
		return null;
	let enc = { '1': 'none', '32': 'psk2', '64': 'sae', '96': 'sae-mixed' }[(ord(auth, 0) << 8) | ord(auth, 1)];
	if (enc == null) return null;
	if (enc == 'none')
		return cipher == "\x00\x01" && !length(key) ? { ssid, encryption: enc } : null;
	if (cipher != "\x00\x08" || length(key) < 8 ||
	    (length(key) > 63 && !(enc == 'psk2' && match(key, /^[0-9A-Fa-f]{64}$/))))
		return null;
	return { ssid, encryption: enc, key };
};

let ifname = ARGV[0];
if (!valid_ifname(ifname) || ARGV[1] != 'WPS-NEW-AP-SETTINGS') exit(0);
let settings = length(ARGV) == 3 ? credential(ARGV[2]) : null;
if (!settings) {
	log('WPS registrar credentials rejected');
	exit(1);
}

let lock = fs.open('/var/run/mtwifi-config.lock', 'ae', 0600);
if (!lock?.lock('x')) exit(1);
let conn = ubus.connect(null, 2);
let ctx = uci.cursor();
if (length(ctx.changes('wireless')?.wireless)) exit(1);
let matched = false;
let status = conn?.call('network.wireless', 'status');
for (let radio, state in status ?? {}) {
	if (!state.up || state.pending || state.config?.type != 'mtwifi') continue;
	for (let vif in state.interfaces ?? []) {
		let section = vif.section;
		if (vif.ifname != ifname || ctx.get('wireless', section) != 'wifi-iface' ||
		    ctx.get('wireless', section, 'device') != radio ||
		    ctx.get('wireless', section, 'mode') != 'ap' ||
		    ctx.get('wireless', section, 'ext_registrar') != '1')
			continue;
		if (ctx.get('wireless', radio, 'band') == '6g') exit(1);
		for (let field, value in settings)
			if (!ctx.set('wireless', section, field, value)) exit(1);
		if (!settings.key) ctx.delete('wireless', section, 'key');
		ctx.delete('wireless', section, 'ieee80211w');
		matched = ctx.commit('wireless');
		break;
	}
	if (matched) break;
}
lock.close();
if (!matched) exit(1);
conn.call('network', 'reload');

'use strict';

import * as libubus from 'ubus';
import * as nl80211 from 'nl80211';
import * as fs from 'fs';
import { atomic_write, daemon_config_write, config_file_exists } from 'mtwifi.common';

global.ubus = libubus.connect();

let config_data = '';
let network_data = '';

const nl80211_bands = [ '2g', '5g', '60g', '6g' ];

export function wiphy_info(phy) {
	let index = trim(fs.readfile(`/sys/class/ieee80211/${phy}/index`) ?? '');
	let digits = match(index, /^[0-9]+$/);
	if (!digits || digits[0] != index)
		return null;
	let idx = +index;
	if (idx > 0x7fffffff)
		return null;

	return nl80211.request(nl80211.const.NL80211_CMD_GET_WIPHY, nl80211.const.NLM_F_DUMP, {
		wiphy: idx,
		split_wiphy_dump: true
	});
};

export function wiphy_band(info, band) {
	let band_idx = index(nl80211_bands, band);
	if (band_idx < 0 || !info)
		return;

	return info.wiphy_bands[band_idx];
};

export function log(msg) {
	printf(`wifi-scripts: ${msg}\n`);
};

export function append_raw(value) {
	config_data += value + '\n';
};

export function append(key, value) {
	if (value == null)
		return;

	switch (type(value)) {
	case 'array':
		value = join(' ', value);
		break;
	case 'bool':
		value = value ? 1 : 0;
		break;
	}

	append_raw(key + '=' + value);
};

function escape_string(value) {
	let chars = map(split(value, ''), (v) => ord(v));
	if (length(filter(chars, (v) => (v < 32 || v >= 128))) > 0)
		return hexenc(value);

	return `"${value}"`;
}

export function append_string(key, value) {
	if (value == null)
		return;

	append(key, escape_string(value));
};

export function append_vars(dict, keys) {
	for (let key in keys)
		append(key, dict[key]);
};

export function append_string_vars(dict, keys) {
	for (let key in keys)
		append_string(key, dict[key]);
};

export function network_append_raw(value) {
	network_data += value + '\n';
};

export function network_append(key, value) {
	if (value == null)
		return;

	switch (type(value)) {
	case 'array':
		value = join(' ', value);
		break;
	case 'bool':
		value = value ? 1 : 0;
		break;
	}

	network_append_raw('\t' + key + '=' + value);
};

export function network_append_string(key, value) {
	if (value == null)
		return;

	network_append_raw('\t' + key + '=' + escape_string(value));
};

export function network_append_vars(dict, keys) {
	for (let key in keys)
		network_append(key, dict[key]);
};

export function network_append_string_vars(dict, keys) {
	for (let key in keys)
		network_append_string(key, dict[key]);
};

export function set_default(dict, key, value) {
	if (dict[key] == null)
		dict[key] = value;
};

export function push_config(dict, key, option, value) {
	if (!dict[option])
		return;

	dict[key] ??= [];
	push(dict[key], value);
};

export function touch_file(filename) {
	if (config_file_exists(filename))
		return;
	if (!daemon_config_write(filename, '', '/var/run/hostapd'))
		die('Failed to create ' + filename);
};

export function append_value(config, key, value) {
	if (!config[key])
		config[key] = value;
	else
		config[key] += ' ' + value;
};

export function comment(comment) {
	append_raw('\n# ' + comment);
};

export function dump_config(file) {
	if (file)
		atomic_write(file, config_data) || die('CONFIG_WRITE_FAILED');

	return config_data;
};

export function dump_network(file) {
	config_data += 'network={\n';
	config_data += network_data;;
	config_data += '}\n';

	if (file)
		atomic_write(file, config_data) || die('CONFIG_WRITE_FAILED');

	return config_data;
};

export function flush_config() {
	config_data = '';
};

export function flush_network() {
	config_data = '';
	network_data = '';
};

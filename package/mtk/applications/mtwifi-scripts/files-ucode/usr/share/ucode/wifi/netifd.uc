'use strict';

import { log } from 'wifi.common';
import * as fs from 'fs';

const CMD_UP = 0;
const CMD_SET_DATA = 1;
const CMD_PROCESS_ADD = 2;
const CMD_PROCESS_KILL_ALL = 3;
const CMD_SET_RETRY = 4;

let pending_notifications;

export function capture_notifications(render) {
	if (pending_notifications != null)
		die('NESTED_NETIFD_TRANSACTION');
	pending_notifications = [];
	try {
		let result = render();
		let notifications = pending_notifications;
		pending_notifications = null;
		return { result, notifications };
	} catch (e) {
		pending_notifications = null;
		die(e);
	}
};

export function notify(command, params, data) {
	params ??= {};
	data ??= {};
	if (pending_notifications != null) {
		push(pending_notifications, { command, params, data });
		return;
	}

	global.ubus.call('network.wireless', 'notify', { command, device: global.radio, ...params, data });
};

export function set_up() {
	notify(CMD_UP);
};

export function set_data(data) {
	notify(CMD_SET_DATA, null, data);
};

export function add_process(exe, pid, required, keep) {
	exe = fs.realpath(exe);

	notify(CMD_PROCESS_ADD, null, { pid, exe, required, keep });
};

export function set_retry(retry) {
	notify(CMD_SET_RETRY, null, { retry });
};

export function set_vif(interface, ifname) {
	notify(CMD_SET_DATA, { interface }, { ifname });
};

export function set_vlan(interface, ifname, vlan) {
	notify(CMD_SET_DATA, { interface, vlan }, { ifname });
};

export function setup_failed(reason) {
	log(`Device setup failed: ${reason}`);
	printf('%s\n', reason);
	set_retry(false);
};

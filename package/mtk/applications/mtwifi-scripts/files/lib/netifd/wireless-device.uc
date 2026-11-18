'use strict';
import * as ubus from "ubus";
import * as uloop from "uloop";
import { is_equal } from "./utils.uc";
import { access } from "fs";

const NOTIFY_CMD_UP = 0;
const NOTIFY_CMD_SET_DATA = 1;
const NOTIFY_CMD_PROCESS_ADD = 2;
const NOTIFY_CMD_SET_RETRY = 4;
const NOTIFY_CMD_RESTORE_CONFIG = 5;
const NOTIFY_CMD_DEFER_SETUP = 6;

const DEFAULT_RETRY = 3;
const DEFAULT_SCRIPT_TIMEOUT = 30 * 1000;

let wdev_cur;
let wdev_handler = {};
let deferred_handlers = 0;
let handler_timer;

function wireless_config_done()
{
	ubus.call({
		object: "wpa_supplicant",
		method: "mld_start",
		return: "ignore",
		data: { },
	});

	ubus.call({
		object: "service",
		method: "event",
		return: "ignore",
		data: {
			type: "netifd.wireless.done",
			data: {},
		},
	});
}

function delete_wdev(name)
{
	delete netifd.wireless.devices[name];
	gc();
}

function handle_link(dev, data, up)
{
	let config = data.config;
	let bridge_isolate;
	let ap = false;
	if (dev == data.ifname)
		ap = data.type == "vlan" ||
		     (data.type == "vif" && config.mode == "ap");

	let dev_data = {
		external: 2,
		check_vlan: false,
		isolate: !!config.bridge_isolate,
		wireless: true,
		wireless_ap: ap,
	};

	if (ap && config.multicast_to_unicast != null)
		dev_data.multicast_to_unicast = config.multicast_to_unicast ? 1 : 0;

	if (data.type == "vif" && config.mode == "ap") {
		dev_data.wireless_proxyarp = !!config.proxy_arp;
		dev_data.wireless_isolate = !!config.isolate;
	}

	if (up)
		netifd.device_set(dev, dev_data);

	for (let net in config.network)
		netifd.interface_handle_link({
			name: net,
			ifname: dev,
			vlan: config.network_vlan,
			link_ext: true,
			up,
		});
}

function wdev_config_init(wdev)
{
	delete wdev.runtime_data;
	let data = wdev.data;
	let config = data.config;
	let interfaces = {};

	let vif_idx = 0;
	for (let vif in data.vif) {
		let vlan_idx = 0, sta_idx = 0;
		let vlans = {}, stas = {};

		if (wdev.disabled_vifs[vif.name])
			continue;
		for (let vlan in vif.vlan) {
			let vlan_name = sprintf("%02d", ++vlan_idx);
			let cur_vlan = vlans[vlan_name] = {
				name: vlan.name,
				config: vlan.config,
			};

			if (wdev.disabled_vifs[vif.name])
				continue;
			for (let net in vlan.config.network)
				if (netifd.interface_get_bridge(net, cur_vlan))
					break;
		}

		for (let sta in vif.sta) {
			let sta_name = sprintf("%02d", ++sta_idx);
			stas[sta_name] = {
				name: sta.name,
				config: sta.config,
			};
		}

		let vif_name = sprintf("%02d", ++vif_idx);
		let iface = interfaces[vif_name] = {
			name: vif.name,
			config: vif.config,
			vlans, stas,
		};

		for (let net in vif.config.network)
			if (netifd.interface_get_bridge(net, iface))
				break;
	}

	wdev.handler_config = {
		config,
		interfaces,
	};

	let prev = wdev.handler_data;
	wdev.handler_data = {};

	if (prev && prev[wdev.name])
		wdev.handler_data[wdev.name] = prev[wdev.name];
}

function wdev_setup_cb(wdev)
{
	if (wdev.state != "setup") {
		if (wdev.state == "up" && wdev.config_change) {
			wdev_config_init(wdev);
			wdev.setup();
		}
		return;
	}

	if (!wdev.cancel_setup && !wdev.config_change) {
		if (wdev.retry > 0)
			wdev.retry--;
		else
			wdev.retry_setup_failed = true;
	}

	wdev.teardown();
}

function wdev_teardown_cb(wdev, status)
{
	for (let section, data in wdev.handler_data) {
		if (data.ifname)
			handle_link(data.ifname, data, false);
	}

	if (wdev.data.config.type == "mtwifi" && status) {
		netifd.log(netifd.L_NOTICE, `wireless: ${wdev.name}: teardown failed; retaining cleanup state\n`);
		wdev.state = "up";
		wdev.teardown_failed = true;
		wdev.retry_setup_failed = true;
		return;
	}
	delete wdev.teardown_failed;
	if (wdev.activation?.phase != "failed")
		delete wdev.activation;
	wdev.handler_data = {};
	wdev.state = "down";
	if (wdev.runtime_data || (wdev.data.config.type == "mtwifi" && wdev.config_change))
		wdev_config_init(wdev);

	if (wdev.delete) {
		delete_wdev(wdev.data.name);
		return;
	}

	wdev.setup();
}

function run_handler_cb(job, status)
{
	if (job.done)
		return;
	job.done = true;

	let wdev = job.wdev;
	wdev.dbg("complete " + job.op);
	job.timeout?.cancel();
	job.task = null;
	if (wdev_cur == job)
		wdev_cur = null;
	if (wdev.setup_waiting == job) {
		delete wdev.setup_waiting;
		deferred_handlers--;
	}
	handler_timer.set(1);
	job.cb(wdev, status ?? 0);
}

function run_handler_timeout(job)
{
	job.task.cancel();
	run_handler_cb(job, 1);
}

function handler_sort_fn(a, b)
{
	return wdev_handler[a].time - wdev_handler[b].time
}

function __run_next_handler_name()
{
	return sort(keys(wdev_handler), handler_sort_fn)[0];
}

function __run_next_handler()
{
	let name = __run_next_handler_name();
	if (!name)
		return;

	let job = wdev_cur = wdev_handler[name];
	delete wdev_handler[name];

	let wdev = job.wdev;
	let op = job.op;

	wdev.dbg("run " + op);
	wdev.handler_config.data = wdev.handler_data[wdev.name] ?? {};
	job.task = netifd.process({
		cb: (status) => run_handler_cb(job, status),
		dir: netifd.wireless.path,
		argv: [ './' + wdev.script, wdev.data.config.type, op, wdev.name, "" + wdev.handler_config ],
		log_prefix: wdev.name,
	});

	if (!job.task)
		return run_handler_cb(job, 1);

	/* MTK config_add may wait up to 90 seconds before deferred ACS/CAC begins. */
	let timeout = op == "setup" && wdev.data.config.type == "mtwifi" ? 120000 : DEFAULT_SCRIPT_TIMEOUT;
	job.timeout = uloop.timer(timeout, () => run_handler_timeout(job));
}

function run_next_handler()
{
	while (!wdev_cur && length(wdev_handler) > 0)
		__run_next_handler();

	if (!wdev_cur && !length(wdev_handler) && !deferred_handlers)
		wireless_config_done();
}

function run_handler(wdev, op, cb)
{
	wdev.dbg("queue " + op);
	wdev_handler[wdev.name] = {
		op, wdev, cb,
		time: time()
	};

	run_next_handler();
}

function wdev_proc_reset(wdev)
{
	if (wdev.proc_timer) {
		wdev.proc_timer.cancel();
		delete wdev.proc_timer;
	}

	wdev.procs = [];
}

function __wdev_proc_check(wdev, proc)
{
	if (netifd.process_check(proc.pid, proc.exe))
		return;

	wdev.dbg(`process ${proc.exe}(${proc.pid}) no longer active`);
	wdev.teardown();
	return true;
}

function wdev_proc_check(wdev)
{
	for (let proc in wdev.procs)
		if (__wdev_proc_check(wdev, proc))
			break;
}

function wdev_proc_add(wdev, data)
{
	if (!data.pid || !data.exe ||
	    length(filter(wdev.procs, p => p.pid == data.pid && p.exe == data.exe)))
		return;

	push(wdev.procs, data);

	if (!wdev.proc_timer)
		wdev.proc_timer = uloop.interval(1000, () => wdev_proc_check(wdev));
}


function setup()
{
	if (this.state != "up" && this.state != "down")
		return;

	this.dbg("setup, state=" + this.state);
	if (!this.autostart || this.retry_setup_failed)
		return;

	if (this.teardown_failed)
		return this.teardown();

	if (this.state == "up" && this.data.config.type == "mtwifi")
		this.previous_procs = this.procs;
	wdev_proc_reset(this);
	delete this.config_change;
	delete this.activation;
	this.state = "setup";
	run_handler(this, "setup", wdev_setup_cb);
}

function teardown()
{
	if (this.setup_waiting) {
		this.cancel_setup = true;
		return;
	}
	delete this.cancel_setup;

	this.dbg("teardown, state=" + this.state);
	if (this.state == "teardown" || this.state == "down")
		return;

	delete this.teardown_failed;
	delete this.previous_procs;
	wdev_proc_reset(this);
	this.state = "teardown";
	run_handler(this, "teardown", wdev_teardown_cb);
}

function wdev_update_disabled_vifs(wdev)
{
	let cache = wdev.ifindex_cache;
	let prev_disabled = wdev.disabled_vifs;
	let disabled = wdev.disabled_vifs = {};
	let changed;

	let vifs = [];
	for (let vif in wdev.data.vif)
		push(vifs, vif, ...vif.vlan);

	for (let vif in vifs) {
		let enabled, ifindex;

		for (let net in vif.config.network) {
			let state = netifd.interface_get_enabled(net);
			if (!state)
				continue;

			if (state.enabled)
				enabled = true;
			else if (enabled == null)
				enabled = false;
			if (state.ifindex)
				ifindex = state.ifindex;
		}

		let name = vif.name;
		if (enabled == false)
			disabled[name] = true;
		else if (ifindex != cache[name])
			changed = true;

		if (ifindex)
			cache[name] = ifindex;
		else
			delete cache[name];
	}

	if (changed || !is_equal(prev_disabled, disabled))
		wdev.config_change = true;

	return wdev.config_change;
}

function wdev_reset(wdev)
{
	wdev.retry = DEFAULT_RETRY;
	delete wdev.retry_setup_failed;
}

function update(data)
{
	if (is_equal(this.data, data))
		return;

	if (data) {
		this.data = data;
		this.ifindex_cache = {};
		delete this.retry_setup_failed;
		delete this.delete;
	}

	wdev_reset(this);
	this.config_change = true;
	this.check();
}

function start()
{
	if (this.delete)
		return;

	this.dbg("start, state=" + this.state);
	this.autostart = true;

	wdev_reset(this);

	if (this.teardown_failed)
		return this.teardown();

	if (this.state != "down")
		return;

	if (wdev_update_disabled_vifs(this))
		wdev_config_init(this);
	this.setup();
}


function retry_setup()
{
	if (this.delete)
		return;

	if (this.state != "down" || !this.autostart)
		return;

	this.start();
}


function stop()
{
	this.dbg("stop, state=" + this.state);
	this.autostart = false;

	switch (this.state) {
	case "setup":
		this.cancel_setup = true;
		break;
	case "up":
		this.teardown();
		break;
	}
}

function check()
{
	if (!wdev_update_disabled_vifs(this))
		return;

	if (this.teardown_failed)
		return this.teardown();

	if (this.setup_waiting)
		return;
	wdev_config_init(this);
	this.setup();
}

function wdev_mark_up(wdev)
{
	wdev.dbg("mark up, state=" + wdev.state);
	if (wdev.state != "setup")
		return;

	for (let section, data in wdev.handler_data) {
		if (data.ifname)
			handle_link(data.ifname, data, true);
	}
	wdev.state = "up";

	return 0;
}

function wdev_set_data(wdev, vif, vlan, data)
{
	let config = wdev.handler_config;
	let cur = { name: wdev.name };
	let cur_type = "device";
	if (!config)
		return ubus.STATUS_INVALID_ARGUMENT;

	if (vif) {
		cur = vif = config.interfaces[vif];
		if (!vif)
			return ubus.STATUS_NOT_FOUND;
		cur_type = "vif";
	}

	if (vlan) {
		if (!vif)
			return ubus.STATUS_INVALID_ARGUMENT;

		cur = vlan = vif.vlans[vlan];
		if (!vlan)
			return ubus.STATUS_NOT_FOUND;

		cur_type = "vlan";
	}

	let key = cur.name;
	if (cur_type == "vlan")
		key = vif.name + "/" + vlan.name;

	wdev.handler_data[key] = {
		...cur,
		...data,
		type: cur_type,
		config: cur.config,
	};

	return 0;
}

function notify(req)
{
	let vif = req.args.interface;
	let vlan = req.args.vlan;
	let data = req.args.data;

	switch (req.args.command) {
	case NOTIFY_CMD_UP:
		if (vif || vlan || this.state != "setup" ||
		    (this.data.config.type == "mtwifi" &&
		     (!this.autostart || this.cancel_setup || this.config_change)))
			return ubus.STATUS_INVALID_ARGUMENT;

		if (this.activation?.phase == "restored")
			for (let proc in this.previous_procs ?? [])
				if (netifd.process_check(proc.pid, proc.exe))
					wdev_proc_add(this, proc);
		delete this.previous_procs;
		return wdev_mark_up(this);
	case NOTIFY_CMD_SET_DATA:
		if (!vif && !vlan && this.data.config.type == "mtwifi" && data?.activation)
			this.activation = data.activation;
		return wdev_set_data(this, vif, vlan, data);
	case NOTIFY_CMD_PROCESS_ADD:
		if (this.state != "setup" && this.state != "up")
			return 0;

		wdev_proc_add(this, data);
		return 0;
	case NOTIFY_CMD_SET_RETRY:
		if (data.retry != null)
			this.retry = data.retry;
		else
			this.retry = DEFAULT_RETRY;
		return 0;
	case NOTIFY_CMD_DEFER_SETUP:
		let job = wdev_cur;
		if (this.data.config.type != "mtwifi" || this.state != "setup" ||
		    !job?.task || job.wdev != this || job.op != "setup")
			return ubus.STATUS_INVALID_ARGUMENT;
		job.timeout.cancel();
		/* DFS CAC can last 600 seconds. Release the handler queue while waiting. */
		job.timeout = uloop.timer(690000, () => run_handler_timeout(job));
		this.setup_waiting = job;
		deferred_handlers++;
		wdev_cur = null;
		handler_timer.set(1);
		return 0;
	case NOTIFY_CMD_RESTORE_CONFIG:
		/* A failed MTK rebuild may restore an older interface order and bridge. */
		if (this.state != "setup" || this.data.config.type != "mtwifi" ||
		    length(filter(keys(this.handler_data), k => k != this.name)) ||
		    type(data.config) != "object" ||
		    type(data.interfaces) != "object" ||
		    (data.config.devname ?? this.name) != (this.data.config.devname ?? this.name))
			return ubus.STATUS_INVALID_ARGUMENT;
		this.handler_config = data;
		this.runtime_data = { config: data.config, vif: [] };
		for (let _, iface in data.interfaces)
			push(this.runtime_data.vif, { ...iface,
				vlan: map(keys(iface.vlans ?? {}), k => iface.vlans[k]),
				sta: map(keys(iface.stas ?? {}), k => iface.stas[k]),
			});
		return 0;
	default:
		return ubus.STATUS_INVALID_ARGUMENT;
	}
}

function hotplug(name, add)
{
	let dev = name;
	let m = match(name, /(.+)\.sta.+/);
	if (m)
		name = m[1];

	for (let section, data in this.handler_data) {
		if (data.ifname != name ||
		    data.type != "vif" && data.type != "vlan")
			continue;

		handle_link(dev, data, add);
	}
}

function get_status_data(wdev, vif, parent_vif)
{
	let key = vif.name;
	if (parent_vif)
		key = parent_vif.name + "/" + vif.name;

	let hdata = wdev.handler_data[key];
	let data = {
		section: vif.name,
		config: vif.config
	};
	if (hdata && hdata.ifname)
		data.ifname = hdata.ifname;
	return data;
}

function get_status_vlans(wdev, vif)
{
	let vlans = [];
	for (let vlan in vif.vlan)
		push(vlans, get_status_data(wdev, vlan, vif));
	return vlans;
}

function get_status_stations(wdev, vif)
{
	let vlans = [];
	for (let vlan in vif.sta)
		push(vlans, get_status_data(wdev, vlan));
	return vlans;
}

function status()
{
	let runtime = this.runtime_data ?? this.data;
	let interfaces = [];
	for (let vif in runtime.vif) {
		let vlans = get_status_vlans(this, vif);
		let stations = get_status_stations(this, vif);
		let data = get_status_data(this, vif);
		push(interfaces, {
			...data,
			vlans, stations
		});
	}
	return {
		up: this.state == "up",
		pending: this.state == "setup" || this.state == "teardown" || !!this.teardown_failed,
		teardown_failed: !!this.teardown_failed,
		autostart: this.autostart,
		disabled: !!runtime.config.disabled,
		retry_setup_failed: !!this.retry_setup_failed,
		...(this.data.config.type == "mtwifi" ? {
			activation: this.activation,
			activation_canceled: !!this.setup_waiting && (!!this.cancel_setup || !!this.config_change)
		} : {}),
		config: runtime.config,
		interfaces
	};
}

function destroy()
{
	this.dbg("destroy");
	this.autostart = false;
	this.delete = true;
	if (this.state != "down") {
		this.stop();
		return;
	}

	delete_wdev(this.data.name);
}

function dbg(msg)
{
	netifd.log(netifd.L_DEBUG, `wireless: ${this.name}: ${msg}\n`);
}

const wdev_proto = {
	update,
	destroy,
	retry_setup,
	start,
	stop,
	setup,
	status,
	teardown,
	check,
	notify,
	hotplug,
	dbg,
};

export function new(data, script, driver)
{
	let wdev = {
		name: data.name,
		script, data,
		procs: [],
		vifs: {},
		disabled_vifs: {},
		ifindex_cache: {},

		autostart: true,
		state: "down",
	};
	wdev_update_disabled_vifs(wdev);
	wdev_config_init(wdev);
	handler_timer = uloop.timer(1, run_next_handler);
	return proto(wdev, wdev_proto);
};

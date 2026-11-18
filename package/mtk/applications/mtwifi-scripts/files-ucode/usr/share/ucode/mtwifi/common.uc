'use strict';

// SPDX-License-Identifier: GPL-2.0
/*
 * mtwifi ucode support - common helpers
 *
 * Copyright (C) 2026 nanchuci <nanchuci023@gmail.com>
 *
 * Port of files/mtwifi-cfg/mtwifi_utils.lua to ucode.
 */

import * as fs from 'fs';

let pending_files;

const LOG_FILE = '/tmp/mtwifi.log';

/*
 * shell 参数转义（等价于把参数用单引号包起来）。
 * 用于拼接 mwctl / ip / logger 等命令行。
 * 不使用 /g 正则标志，改用 split/join 做全局替换。
 */
export function shell_quote(s) {
	if (s == null)
		return "''";

	return "'" + join("'\\''", split('' + s, "'")) + "'";
};

/*
 * 与 shell 的 log_msg()/logger -t 等价。
 * 注意：netifd 的 handler "dump" 操作会解析 stdout 中的 JSON 行，
 * 所以 dump 路径里不要调用 log()；这里统一走 stderr。
 */
export function log(msg) {
	warn(`mtwifi: ${msg}\n`);
};

/*
 * 同时写 syslog 与 stderr：netifd 会把 handler 的 stdout/stderr 收进
 * log_prefix 标记的日志里，所以 warn() 已经足够，syslog 走 logger 命令。
 */
export function log_syslog(msg) {
	warn(`mtwifi: ${msg}\n`);
	system(`logger -t mtwifi ${shell_quote(msg)}`);
};

export function trim(s) {
	if (s == null)
		return null;

	return replace(replace('' + s, /^\s+/, ''), /\s+$/, '');
};

export function rtrim(s) {
	if (s == null)
		return null;

	return replace('' + s, /\s+$/, '');
};

export function exists(path) {
	return fs.stat(path) != null;
};

export function config_file_exists(path) {
	for (let file in pending_files ?? [])
		if (file.path == path)
			return true;
	return exists(path);
};

export function readfile(path) {
	try {
		return fs.readfile(path);
	} catch (e) {
		return null;
	}
};

export function writefile(path, data) {
	try {
		return fs.writefile(path, data);
	} catch (e) {
		log(`failed to write ${path}: ${e}`);
		return null;
	}
};

export function glob(pattern) {
	try {
		return fs.glob(pattern) ?? [];
	} catch (e) {
		return [];
	}
};

/* 与 mtwifi_utils.read_pipe 等价的、带重试的管道读取 */
export function read_pipe(cmd) {
	let retry = 10;
	let txt = null;

	while (retry-- > 0) {
		let p = fs.popen(cmd);
		if (!p)
			break;
		try {
			txt = p.read('all');
		} catch (e) {
			txt = null;
		}
		p.close();
		if (txt != null)
			break;
	}

	return txt;
};

/* MTK callers use seconds; the ucode core sleep() takes milliseconds. */
export function sleep(sec) {
	if (sec > 0)
		global.sleep(int(sec * 1000));
};

/* 与 mtwifi_utils.log2file 等价 */
export function timestr() {
	let t = localtime();

	return sprintf('%02d:%02d:%02d', t.hour, t.min, t.sec);
};

export function log2file(str) {
	let f = fs.open(LOG_FILE, 'a');
	if (!f)
		return;

	f.write(sprintf('%s %s\n', timestr(), str));
	f.close();
};

/* 把 object 转成可读字符串，替代原来 require("inspect") 的调试输出 */
export function dump(obj) {
	return sprintf('%.J', obj);
};

export function basename(path) {
	return fs.basename(path);
};

export function dirname(path) {
	return fs.dirname(path);
};

/* Same-filesystem rename: never truncate the live profile or expose credentials. */
export function atomic_write(path, text, owner) {
	let dir = fs.mkdtemp(path + '.XXXXXX');
	if (!dir)
		return false;
	let tmp = dir + '/data';
	let file = fs.open(tmp, 'w', 0600);
	let ok = file != null;
	if (file) {
		ok = file.write(text) == length(text) && file.flush();
		file.close();
	}
	if (ok && owner != null)
		ok = fs.chown(tmp, owner.uid, owner.gid);
	if (ok)
		ok = fs.rename(tmp, path);
	fs.unlink(tmp);
	fs.rmdir(dir);
	return !!ok;
};

/* wpad may run as network under ujail; keep credentials private to that owner. */
export function daemon_config_write(path, text, control_dir) {
	let owner = fs.stat(control_dir ?? fs.dirname(path));
	if (owner == null)
		return false;
	if (pending_files != null) {
		for (let file in pending_files)
			if (file.path == path) {
				file.text = text;
				return true;
			}
		let previous = readfile(path);
		let previous_owner = fs.stat(path);
		if (previous_owner != null && previous == null)
			return false;
		push(pending_files, { path, text, owner, previous, previous_owner });
		return true;
	}
	return atomic_write(path, text, owner);
};

/* Render daemon configuration without modifying any live credential file. */
export function capture_files(render) {
	if (pending_files != null)
		die('NESTED_CONFIG_TRANSACTION');
	pending_files = [];
	try {
		let result = render();
		let files = pending_files;
		pending_files = null;
		return { result, files };
	} catch (e) {
		pending_files = null;
		die(e);
	}
};

export function rollback_files(plan) {
	let ok = true;
	for (let file in reverse(plan?.committed ?? [])) {
		if (file.text != null) {
			let current = readfile(file.path);
			if (current == file.previous) {
				let owner = fs.stat(file.path);
				if (!owner || !file.previous_owner ||
				    owner.uid == file.previous_owner.uid && owner.gid == file.previous_owner.gid)
					continue;
			} else if (current != file.text) {
				log(`configuration changed during activation: ${file.path}`);
				ok = false;
				continue;
			}
		}
		if (file.previous != null)
			ok = atomic_write(file.path, file.previous, file.previous_owner) && ok;
		else if (fs.stat(file.path))
			ok = !!fs.unlink(file.path) && ok;
	}
	if (ok)
		plan.committed = [];
	return ok;
};

export function commit_files(plan) {
	plan.committed = [];
	for (let file in plan.files) {
		if (!atomic_write(file.path, file.text, file.owner)) {
			rollback_files(plan);
			return false;
		}
		push(plan.committed, file);
	}
	return true;
};

export function valid_ifname(name) {
	return type(name) == 'string' && length(name) <= 15 &&
		match(name, /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/) != null;
};

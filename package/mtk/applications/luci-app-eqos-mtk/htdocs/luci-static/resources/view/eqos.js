'use strict';
'require form';
'require network';
'require uci';
'require view';
'require rpc';
'require poll';
'require ui';


var callStatus = rpc.declare({ object: 'luci.eqos', method: 'getStatus', expect: { '': {} } });

var callApply = rpc.declare({ object: 'luci.eqos', method: 'apply', expect: { '': {} } });

function statusLabel(state) {
	if (state.schema !== 1) return '无法获取状态';
	if (state.error) return '应用失败';
	if (state.enabled !== true) return state.owned ? '待清理' : '未开启';
	if (!state.hnat) return '等待 HNAT';
	return state.applied ? '运行中' : state.rules > 0 ? '待应用' : '已开启，未设置限速';
}

function nextQueue(exclude, engine) {
	var used = {};
	uci.sections('eqos', 'device').forEach(function(s) {
		if (s['.name'] !== exclude) used[Number(s.queue || s.comment)] = true;
	});
	for (var n = engine === 'software' ? 32 : 1, max = engine === 'hardware' ? 31 : 65535; n <= max; n++) if (!used[n]) return n;
	return null;
}

function collectHostChoices(hosts) {
	var choices = {
		ip: [],
		ip6: []
	};

	for (var host in hosts) {
		var ipaddrs = L.toArray(hosts[host].ipaddrs || hosts[host].ipv4);
		var ip6addrs = L.toArray(hosts[host].ip6addrs || hosts[host].ipv6);
		var name = hosts[host].name;

		for (var i = 0; i < ipaddrs.length; i++)
			choices.ip.push([ ipaddrs[i], name ? '%s (%s)'.format(name, ipaddrs[i]) : ipaddrs[i] ]);

		for (var j = 0; j < ip6addrs.length; j++)
			choices.ip6.push([ ip6addrs[j], name ? '%s (%s)'.format(name, ip6addrs[j]) : ip6addrs[j] ]);
	}

	return choices;
}

function addChoices(option, choices) {
	for (var i = 0; i < choices.length; i++)
		option.value(choices[i][0], choices[i][1]);
}

function selectorValue(section_id) {
	var selector = uci.get('eqos', section_id, 'selector');

	if (selector === 'ip' || selector === 'ip6')
		return selector;

	if (uci.get('eqos', section_id, 'ip6'))
		return 'ip6';

	return 'ip';
}

function matchLabel(selector) {
	if (selector === 'ip6')
		return _('IPv6 address');

	return _('IPv4 address');
}

function rateCfgvalue(section_id) {
	return String(Number(uci.get('eqos', section_id, this.option) || 0) / 1000);
}

function rateValidate(section_id, value) {
	var rate = Number(value), kbit = rate * 1000;
	return Number.isFinite(rate) && rate >= 0 && rate <= 1000 && (rate === 0 || kbit >= 1) &&
		Math.abs(kbit - Math.round(kbit)) < 0.000001 ||
		_('速率最多保留三位小数，0 表示不限制。');
}

function rateWrite(section_id, value) {
	uci.set('eqos', section_id, this.option, String(Math.round(Number(value) * 1000)));
}

function integerWrite(section_id, value) {
	uci.set('eqos', section_id, this.option, String(Number(value)));
}

function uniqueAddress(section_id, value) {
	var sections = uci.sections('eqos', 'device');

	for (var i = 0; i < sections.length; i++) {
		if (sections[i]['.name'] === section_id || sections[i].enabled === '0')
			continue;

		if (sections[i][this.option] === value)
			return _('This value is already in use.');
	}

	return true;
}

function rateText(section_id) {
	var value = this.cfgvalue(section_id) || '0';

	return value === '0' ? _('unlimited') : '%s Mbit/s'.format(value);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('eqos'),
			network.getHostHints(),
			L.resolveDefault(callStatus(), {})
		]);
	},

	render: function(data) {
		var hosts = data[1] ? data[1].hosts || {} : {};
		var hostChoices = collectHostChoices(hosts);
		var m, s, o;

		m = new form.Map('eqos', _('EQoS'),
			_('按设备设置下载和上传上限。服务默认关闭，保存并应用后生效。'));

		s = m.section(form.NamedSection, 'config', 'eqos', _('Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用限速服务'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'download', '%s (Mbit/s)'.format(_('Download')),
			_('硬件限速设备的总下载上限，0 表示不限制。'));
		o.datatype = 'and(uinteger,min(0),max(1000))';
		o.rmempty = false;
		o.write = integerWrite;

		o = s.option(form.Value, 'upload', '%s (Mbit/s)'.format(_('Upload')),
			_('硬件限速设备的总上传上限，0 表示不限制。'));
		o.datatype = 'and(uinteger,min(0),max(1000))';
		o.rmempty = false;
		o.write = integerWrite;

		s = m.section(form.GridSection, 'device', _('Device rules'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.handleAdd = function(ev) {
			var section_id = uci.add('eqos', 'device');

			uci.set('eqos', section_id, 'enabled', '1');
			uci.set('eqos', section_id, 'queue', String(nextQueue(section_id)));
			uci.set('eqos', section_id, 'selector', 'ip');
			uci.set('eqos', section_id, 'download', '0');
			uci.set('eqos', section_id, 'upload', '0');
			m.addedSection = section_id;

			return this.renderMoreOptionsModal(section_id);
		};

		s.tab('general', _('General Settings'));

		o = s.taboption('general', form.Flag, 'enabled', _('Enable'));
		o.default = o.enabled;
		o.rmempty = false;
		o.editable = true;

		o = s.taboption('general', form.ListValue, '_engine', _('限速方式'));
		o.modalonly = true;
		o.value('hardware', _('硬件限速'));
		o.value('software', _('软件限速'));
		o.description = _('普通硬件转发使用硬件限速；代理等软件转发使用软件限速。');
		o.cfgvalue = function(section) {
			return Number(uci.get('eqos', section, 'queue') || uci.get('eqos', section, 'comment') || 1) <= 31 ? 'hardware' : 'software';
		};
		o.validate = function(section, value) {
			return nextQueue(section, value) !== null || _('硬件队列已用满，请选择软件限速。');
		};
		o.write = function(section, value) {
			var current = Number(uci.get('eqos', section, 'queue') || uci.get('eqos', section, 'comment'));
			if (!current || (current <= 31) !== (value === 'hardware')) current = nextQueue(section, value);
			uci.set('eqos', section, 'queue', String(current));
			uci.unset('eqos', section, 'comment');
		};
		o = s.option(form.DummyValue, '_path', _('限速方式'));
		o.textvalue = function(section) {
			return Number(uci.get('eqos', section, 'queue') || uci.get('eqos', section, 'comment') || 1) <= 31 ? _('硬件限速') : _('软件限速');
		};

		o = s.option(form.DummyValue, '_match', _('Address'));
		o.textvalue = function(section_id) {
			var selector = selectorValue(section_id);
			var value = uci.get('eqos', section_id, selector);

			return value ? '%s: %s'.format(matchLabel(selector), value) : E('em', _('unspecified'));
		};

		o = s.taboption('general', form.Value, 'download', _('Download'),
			_('Maximum rate in Mbit/s. Use 0 for no limit.'));
		o.datatype = 'and(ufloat,min(0),max(1000))';
		o.rmempty = false;
		o.cfgvalue = rateCfgvalue;
		o.write = rateWrite;
		o.validate = rateValidate;
		o.textvalue = rateText;

		o = s.taboption('general', form.Value, 'upload', _('Upload'),
			_('Maximum rate in Mbit/s. Use 0 for no limit.'));
		o.datatype = 'and(ufloat,min(0),max(1000))';
		o.rmempty = false;
		o.cfgvalue = rateCfgvalue;
		o.write = rateWrite;
		o.validate = rateValidate;
		o.textvalue = rateText;

		o = s.taboption('general', form.ListValue, 'selector', _('Type'));
		o.modalonly = true;
		o.default = 'ip';
		o.rmempty = false;
		o.value('ip', _('IPv4 address'));
		o.value('ip6', _('IPv6 address'));
		o.cfgvalue = function(section_id) {
			return selectorValue(section_id);
		};
		o.write = function(section_id, value) {
			uci.set('eqos', section_id, 'selector', value);

			if (value !== 'ip')
				uci.unset('eqos', section_id, 'ip');

			if (value !== 'ip6')
				uci.unset('eqos', section_id, 'ip6');
		};

		o = s.taboption('general', form.Value, 'ip', _('IPv4 address'));
		o.modalonly = true;
		o.datatype = 'ip4addr("nomask")';
		o.rmempty = false;
		o.depends('selector', 'ip');
		o.validate = uniqueAddress;
		addChoices(o, hostChoices.ip);

		o = s.taboption('general', form.Value, 'ip6', _('IPv6 address'));
		o.modalonly = true;
		o.datatype = 'ip6addr("nomask")';
		o.rmempty = false;
		o.depends('selector', 'ip6');
		o.validate = uniqueAddress;
		addChoices(o, hostChoices.ip6);

		var state = data[2] || {};
		var service = E('strong', {}, statusLabel(state));
		var hnat = E('strong', {}, state.hnat === true ? '已开启' : state.hnat === false ? '未开启' : '无法读取');
		var retry = E('button', { 'class': 'cbi-button cbi-button-apply', 'disabled': (!state.enabled && !state.owned) || !L.hasViewPermission(), 'click': ui.createHandlerFn(this, function() {
			return callApply().then(function(result) {
				if (!result.success) ui.addNotification(null, E('p', {}, '应用失败，请查看页面提示和系统日志。'));
				return callStatus();
			}).then(updateState);
		}) }, '重新应用已保存配置');
		var error = E('div', { 'class': 'eqos-error', 'style': state.error ? '' : 'display:none' }, state.error || '');
		var rules = uci.sections('eqos', 'device').filter(function(s) { return s.enabled !== '0' && (Number(s.download) > 0 || Number(s.upload) > 0); }).length;
		var cards = E('div', { 'class': 'eqos-cards' }, [
			E('div', { 'class': 'eqos-card' }, [ E('span', {}, '服务状态'), service ]),
			E('div', { 'class': 'eqos-card' }, [ E('span', {}, '已启用规则'), E('strong', {}, String(rules)) ]),
			E('div', { 'class': 'eqos-card' }, [ E('span', {}, 'MediaTek HNAT'), hnat ])
		]);
		function updateState(state) {
			service.textContent = statusLabel(state);
			service.className = state.error ? 'eqos-bad' : state.applied ? 'eqos-good' : 'eqos-neutral';
			retry.disabled = (!state.enabled && !state.owned) || !L.hasViewPermission();
			hnat.textContent = state.hnat === true ? '已开启' : state.hnat === false ? '未开启' : '无法读取';
			error.textContent = state.error || '';
			error.style.display = state.error ? '' : 'none';
		}
		updateState(state);
		poll.add(function() { return callStatus().then(updateState); }, 5);
		return m.render().then(function(form) {
			return E('div', { 'class': 'mtk-eqos' }, [
				E('style', {}, '.mtk-eqos{max-width:1280px;margin:auto}.mtk-eqos .eqos-cards{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;margin:20px 0}.mtk-eqos .eqos-card,.mtk-eqos .cbi-map{border:1px solid rgba(128,128,128,.18);border-radius:20px;padding:20px;background:rgba(128,128,128,.035)}.mtk-eqos .eqos-card span{display:block;opacity:.7;font-size:13px;margin-bottom:12px}.mtk-eqos .eqos-card strong{font-size:21px;color:#00a7dc}.mtk-eqos .eqos-card .eqos-bad{color:#d95c45}.mtk-eqos .eqos-card .eqos-good{color:#22a270}.mtk-eqos .eqos-card .eqos-neutral{color:inherit}.mtk-eqos .eqos-error{padding:14px;border-radius:12px;color:#d95c45;background:rgba(255,122,69,.10);margin-bottom:16px}.mtk-eqos .cbi-map{margin-bottom:20px}.mtk-eqos .cbi-map h2{margin-top:0}@media(max-width:650px){.mtk-eqos .eqos-cards{grid-template-columns:1fr;gap:10px}.mtk-eqos .eqos-card{padding:15px}.mtk-eqos .eqos-card strong{font-size:18px}}'),
				cards, error, form, retry,
				E('p', {}, [ '需要硬件限速时，请先在 ', E('a', { 'href': L.url('admin/mtk/turboacc') }, 'TurboACC'), ' 启用 HNAT。EQoS 不会更改 TurboACC 的持久配置。总带宽填 0 表示不设总上限。' ])
			]);
		});
	}
});

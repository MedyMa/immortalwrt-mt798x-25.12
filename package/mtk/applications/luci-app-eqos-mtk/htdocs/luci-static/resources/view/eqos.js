'use strict';
'require form';
'require network';
'require uci';
'require view';
'require rpc';
'require poll';


var callStatus = rpc.declare({ object: 'luci.eqos', method: 'getStatus', expect: { '': {} } });

var style = `
.mtk-eqos,#cbi-eqos{--eqos-accent:var(--primary,#5e72e4);--eqos-text:#263b58;--eqos-line:#dfe7f1;--eqos-panel:linear-gradient(180deg,rgba(255,255,255,.98),rgba(249,252,255,.99));--eqos-hero:linear-gradient(100deg,#e9f1ff 0%,#f8fbff 52%,#eefbff 100%);--eqos-input:linear-gradient(180deg,#fbfdff,#f5f8fc);--eqos-help-color:#5878a6;--eqos-shadow:0 6px 16px rgba(73,99,135,.08)}
.mtk-eqos{display:grid;gap:18px;width:100%;min-width:0;color:var(--eqos-text)}
.mtk-eqos.eqos-dark,body:has(.mtk-eqos.eqos-dark) #cbi-eqos{--eqos-accent:var(--dark-primary,var(--primary,#5e72e4));--eqos-text:#cbd8ea;--eqos-line:rgba(120,146,188,.22);--eqos-panel:linear-gradient(180deg,rgba(19,29,44,.98),rgba(13,22,35,.99));--eqos-hero:linear-gradient(100deg,rgba(22,34,58,.98),rgba(17,27,48,.98) 52%,rgba(14,34,45,.98));--eqos-input:linear-gradient(180deg,rgba(30,42,60,.98),rgba(18,28,42,.98));--eqos-help-color:#b0cdf0;--eqos-shadow:0 14px 30px rgba(0,0,0,.28)}
#cbi-eqos{color:var(--eqos-text)}
.mtk-eqos *{box-sizing:border-box}
.mtk-eqos .eqos-header,.mtk-eqos .cbi-section{border:1px solid var(--eqos-line);border-radius:20px;background:var(--eqos-panel)!important;box-shadow:var(--eqos-shadow);backdrop-filter:none;padding:22px;margin:0;overflow:visible;position:relative}
.mtk-eqos .eqos-header:has(.eqos-hint:hover,.eqos-hint:focus-within),.mtk-eqos .cbi-section:has(.eqos-hint:hover,.eqos-hint:focus-within){z-index:2}
.mtk-eqos .eqos-header{background:var(--eqos-hero)!important;display:grid;grid-template-columns:minmax(0,1.5fr) minmax(220px,1fr);gap:24px;align-items:center}
.mtk-eqos .eqos-identity{--eqos-icon-space:92px;display:flex;align-items:center;gap:18px;min-width:0}
.mtk-eqos .eqos-identity>div{position:relative;min-width:0}.mtk-eqos .eqos-identity .eqos-hint{position:static;width:100%}
.mtk-eqos .eqos-icon{display:grid;place-items:center;width:74px;height:74px;flex-shrink:0;border-radius:20px;background:linear-gradient(140deg,var(--eqos-accent),color-mix(in srgb,var(--eqos-accent) 72%,white));color:white}
.mtk-eqos .eqos-icon svg{width:48px;height:48px}
.mtk-eqos .eqos-title{margin:0 0 10px;padding:0;border:0;background:none;box-shadow:none;font-size:22px;font-weight:700;color:inherit}
.mtk-eqos .eqos-status{display:inline-flex;align-items:center;gap:7px;padding:5px 11px;border-radius:999px;font-size:13px;background:rgba(128,128,128,.12);color:inherit}
.mtk-eqos .eqos-status::before{content:'';width:7px;height:7px;border-radius:50%;background:currentColor}
.mtk-eqos .eqos-good{color:#159b70}.mtk-eqos .eqos-status.eqos-good{background:rgba(21,155,112,.12)}
.mtk-eqos .eqos-bad{color:var(--red,#f5365c)}.mtk-eqos .eqos-status.eqos-bad{background:rgba(245,54,92,.10)}
.mtk-eqos .eqos-metrics{display:grid;gap:10px;min-width:0}
.mtk-eqos .eqos-metric{border:1px solid var(--eqos-line);border-radius:14px;padding:10px 16px;background:var(--eqos-input)}
.mtk-eqos .eqos-metric>span{display:block;font-size:12px;opacity:.75;margin-bottom:4px}
.mtk-eqos .eqos-metric>strong{font-size:22px;line-height:1.2;color:var(--eqos-accent);font-variant-numeric:tabular-nums}
.mtk-eqos .eqos-metric>strong.eqos-good{color:#159b70}
.mtk-eqos .cbi-map{margin:0;padding:0;border:0;background:transparent!important;box-shadow:none;display:grid;gap:18px;overflow:visible}
.mtk-eqos .cbi-map>h2,.mtk-eqos .cbi-map-descr{display:none}
.mtk-eqos .cbi-section>h3{margin:0 0 18px;padding:0;background:none;border:0;box-shadow:none;color:inherit;font-size:19px;overflow:visible}
.mtk-eqos .cbi-section-node{padding:0;background:none;border:0;box-shadow:none}
.mtk-eqos .cbi-section-node>.cbi-value{display:flex;align-items:center;gap:18px;margin:0;padding:12px 0;background:none;border:0}
.mtk-eqos .cbi-value-title{float:none;flex:0 0 160px;width:160px;padding:0;text-align:left;color:inherit;overflow:visible}
.mtk-eqos .cbi-value-field{margin:0;min-width:0;padding:0;flex:1}
#cbi-eqos input[type=text],#cbi-eqos input[type=number]{width:100%;max-width:420px;min-height:40px;border-radius:10px;background:var(--eqos-input)!important;color:var(--eqos-accent)!important;box-shadow:none}
#cbi-eqos input,#cbi-eqos select,#cbi-eqos .cbi-dropdown{border-color:var(--eqos-accent)!important;accent-color:var(--eqos-accent)}
#cbi-eqos input:focus-visible,#cbi-eqos select:focus-visible,.mtk-eqos .eqos-hint:focus-visible{outline:2px solid var(--eqos-accent);outline-offset:3px}
.mtk-eqos .table{width:100%;margin:0 0 12px;background:transparent}
.mtk-eqos .tr,.mtk-eqos .th,.mtk-eqos .td{background:transparent;color:inherit}
.mtk-eqos .cbi-section-table-titles{background:color-mix(in srgb,var(--eqos-accent) 6%,transparent)}
.mtk-eqos .eqos-error{padding:14px 18px;border:1px solid currentColor;border-radius:12px;color:var(--red,#f5365c);background:rgba(245,54,92,.06)}
.mtk-eqos .eqos-hint{position:relative;display:inline-flex;align-items:center;max-width:100%;cursor:help;outline-offset:3px}
.mtk-eqos .cbi-value-title .eqos-hint::after,.mtk-eqos h3 .eqos-hint::after{content:'ⓘ';font-size:12px;opacity:.6;margin-left:7px}
.mtk-eqos .eqos-tooltip{position:absolute;left:0;bottom:calc(100% + 10px);z-index:1100;display:block;width:max-content;max-width:min(360px,calc(100vw - 64px));padding:13px 15px;border:1px solid var(--eqos-line);border-radius:14px;background:transparent;backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);box-shadow:0 14px 30px rgba(15,23,42,.18);color:var(--eqos-help-color);font-size:.82rem;font-weight:600;line-height:1.55;white-space:normal;text-align:left;opacity:0;visibility:hidden}
.mtk-eqos.eqos-dark .eqos-tooltip{box-shadow:0 14px 30px rgba(0,0,0,.42)}
.mtk-eqos .eqos-identity .eqos-tooltip{left:calc(100% + 12px);top:50%;bottom:auto;transform:translateY(-50%)}
.mtk-eqos .eqos-tooltip::after{content:'';position:absolute;left:0;right:0;bottom:-12px;height:12px}
.mtk-eqos .eqos-identity .eqos-tooltip::after{left:-12px;right:auto;top:0;bottom:0;width:12px;height:auto}
.mtk-eqos .eqos-hint:hover>.eqos-tooltip,.mtk-eqos .eqos-hint:focus-within>.eqos-tooltip{opacity:1;visibility:visible}
.mtk-eqos [hidden]{display:none!important}
@media(max-width:1100px){.mtk-eqos .eqos-identity{align-items:flex-start}.mtk-eqos .eqos-identity>div{flex:1}.mtk-eqos .eqos-identity .eqos-hint{display:flex;flex-direction:column;align-items:flex-start}.mtk-eqos .eqos-identity .eqos-tooltip{position:relative;left:calc(-1 * var(--eqos-icon-space));top:auto;bottom:auto;transform:none;display:none;width:calc(100% + var(--eqos-icon-space));max-width:360px;margin-top:12px}.mtk-eqos .eqos-identity .eqos-hint:hover>.eqos-tooltip,.mtk-eqos .eqos-identity .eqos-hint:focus-within>.eqos-tooltip{display:block}.mtk-eqos .eqos-identity .eqos-tooltip::after{display:none}}
@media(max-width:700px){.mtk-eqos .eqos-identity{--eqos-icon-space:78px}.mtk-eqos .eqos-header{grid-template-columns:1fr;gap:18px}.mtk-eqos .eqos-metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.mtk-eqos .eqos-header,.mtk-eqos .cbi-section{padding:16px;border-radius:16px}.mtk-eqos .eqos-icon{width:60px;height:60px;border-radius:16px}.mtk-eqos .eqos-title{font-size:20px}.mtk-eqos .cbi-value-title{flex-basis:124px;width:124px}.mtk-eqos .cbi-section-node>.cbi-value{gap:10px}}
@media(max-width:430px){.mtk-eqos .cbi-section-node>.cbi-value{align-items:flex-start;flex-direction:column}.mtk-eqos .cbi-value-title{width:auto;flex-basis:auto}.mtk-eqos .cbi-value-field{width:100%}.mtk-eqos .eqos-metric{padding:10px}.mtk-eqos .eqos-metric>strong{font-size:19px}}
`;

function hint(label, text, id) {
	return E('span', { 'class': 'eqos-hint', 'tabindex': '0', 'aria-describedby': 'eqos-help-' + id }, [
		label, E('span', { 'class': 'eqos-tooltip', 'id': 'eqos-help-' + id, 'role': 'tooltip' }, text)
	]);
}

function fieldHint(option, text, id) {
	var renderFrame = option.renderFrame;
	option.renderFrame = function() {
		var frame = renderFrame.apply(this, arguments);
		var label = frame.querySelector('.cbi-value-title');
		if (label) label.replaceChildren(hint(label.textContent, text, id));
		return frame;
	};
}

function speedIcon() {
	var icon = E('span', { 'class': 'eqos-icon', 'aria-hidden': 'true' });
	icon.innerHTML = '<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M9 35a18 18 0 1 1 30 0"/><path d="m24 24 10-10M9 24h3m24 0h3M14 12l2 3m8-9v3m10 3-2 3"/><circle cx="24" cy="24" r="3" fill="currentColor"/></svg>';
	return icon;
}

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
		var m, s, o, page;

		m = new form.Map('eqos');

		s = m.section(form.NamedSection, 'config', 'eqos', _('Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用限速服务'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'download', '%s (Mbit/s)'.format(_('Download')));
		fieldHint(o, _('硬件限速设备的总下载上限，范围 0–1000 Mbit/s，0 表示不限制。'), 'download');
		o.datatype = 'and(uinteger,min(0),max(1000))';
		o.rmempty = false;
		o.write = integerWrite;

		o = s.option(form.Value, 'upload', '%s (Mbit/s)'.format(_('Upload')));
		fieldHint(o, _('硬件限速设备的总上传上限，范围 0–1000 Mbit/s，0 表示不限制。'), 'upload');
		o.datatype = 'and(uinteger,min(0),max(1000))';
		o.rmempty = false;
		o.write = integerWrite;

		s = m.section(form.GridSection, 'device', hint(_('Device rules'), [
			_('需要硬件限速时，请先在 '), E('a', { 'href': L.url('admin/mtk/turboacc') }, 'TurboACC'),
			_(' 启用 HNAT。EQoS 不会更改 TurboACC 的持久配置。总带宽填 0 表示不设总上限。')
		], 'rules'));
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
		var service = E('strong', { 'class': 'eqos-status', 'role': 'status' }, statusLabel(state));
		var hnat = E('strong', {}, state.hnat === true ? '已开启' : state.hnat === false ? '未开启' : '无法读取');
		var error = E('div', { 'class': 'eqos-error', 'style': state.error ? '' : 'display:none' }, state.error || '');
		var rules = uci.sections('eqos', 'device').filter(function(s) { return s.enabled !== '0' && (Number(s.download) > 0 || Number(s.upload) > 0); }).length;
		var count = E('strong', {}, String(rules));
		var header = E('div', { 'class': 'eqos-header' }, [
			E('div', { 'class': 'eqos-identity' }, [ speedIcon(), E('div', {}, [
				E('h2', { 'class': 'eqos-title' }, _('网速控制')),
				hint(service, _('按设备设置下载和上传上限。服务默认关闭，保存并应用后生效。'), 'service')
			]) ]),
			E('div', { 'class': 'eqos-metrics' }, [
				E('div', { 'class': 'eqos-metric' }, [ E('span', {}, _('已启用规则')), count ]),
				E('div', { 'class': 'eqos-metric' }, [ E('span', {}, 'MediaTek HNAT'), hnat ])
			])
		]);
		function updateState(state) {
			service.textContent = statusLabel(state);
			service.className = 'eqos-status ' + (state.error ? 'eqos-bad' : state.applied ? 'eqos-good' : 'eqos-neutral');
			hnat.textContent = state.hnat === true ? '已开启' : state.hnat === false ? '未开启' : '无法读取';
			hnat.className = state.hnat === true ? 'eqos-good' : '';
			if (state.schema === 1) count.textContent = String(state.rules);
			error.textContent = state.error || '';
			error.style.display = state.error ? '' : 'none';
			if (page) {
				var background = getComputedStyle(document.body).backgroundColor.match(/\d+/g);
				page.classList.toggle('eqos-dark', !!(background && Number(background[0]) < 100));
			}
		}
		poll.add(function() { return callStatus().then(updateState); }, 5);
		return m.render().then(function(form) {
			page = E('div', { 'class': 'mtk-eqos' }, [
				E('style', {}, style), header, error, form
			]);
			updateState(state);
			return page;
		});
	}
});

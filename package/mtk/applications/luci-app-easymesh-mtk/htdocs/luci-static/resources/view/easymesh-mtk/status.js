'use strict';
'require view';
'require rpc';
'require dom';
'require poll';
'require easymesh-mtk.ui as meshUI';
'require easymesh-mtk.clients as clientUI';

var callStatus = rpc.declare({ object: 'easymesh-mtk', method: 'get_status', expect: { '': {} } });
var callClients = rpc.declare({ object: 'easymesh-mtk', method: 'get_clients', expect: { '': {} } });
var callRestart = rpc.declare({ object: 'easymesh-mtk', method: 'restart', expect: { '': {} } });
function read(promise) { return promise.catch(function(e) { return { ok: false, error: e.message }; }); }

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() { return Promise.all([ read(callStatus()), read(callClients()) ]); },

	refresh: function() {
		var self = this;
		return this.load().then(function(data) { self.draw(data[0]); dom.content(self.clientsPanel, clientUI.render(data[1])); });
	},

	draw: function(st) {
		var self = this;
		st = st || {};
		var open = Array.from(this.detailsPanel.querySelectorAll('details')).map(function(n) { return n.open; });
		var valid = st.ok === true, running = valid && st.running === true, enabled = valid && st.enable === '1';
		var state = !valid ? _('Unavailable') : running ? _('Running') : enabled ? _('Not ready') : _('Disabled');
		var tone = !valid ? 'danger' : running ? 'ok' : enabled ? 'warning' : 'neutral';
		var stateNote = !valid ? _('Refresh to retry') : running ? _('Refreshes every 10 seconds') :
			enabled ? _('Expand network details to check services') : _('Enable EasyMesh in Settings');
		var summary = [ E('section', { 'class': 'em-card' }, [ E('div', { 'class': 'em-overview' }, [
			E('div', { 'class': 'em-state', 'role': 'status', 'aria-live': 'polite' }, [ meshUI.badge(state, tone), E('span', { 'class': 'em-note' }, stateNote) ]),
			meshUI.metric(_('Device role'), valid ? meshUI.role(st.role) : '—'),
			meshUI.metric(_('LAN network'), valid ? (st.bridge || '—') : '—'),
			meshUI.metric(_('MAP version'), valid ? st.map_ver : '—')
		]) ]) ];
		if (!valid) summary.push(E('div', { 'class': 'em-notice em-notice-error', 'role': 'alert' }, st.error || _('Unable to read Mesh status.')));
		if (valid && st.mapd_log && st.mapd_log.trim()) summary.push(E('div', { 'class': 'em-notice em-notice-error', 'role': 'alert' }, st.mapd_log));
		dom.content(this.panel, summary);
		var details = [];
		if (valid) {
			var services = [ [ 'mapd', _('Mesh manager') ], [ 'p1905', _('Node discovery') ], [ 'wapp', _('Wireless control') ] ];
			this.serviceNotice = E('div', { 'class': 'em-notice em-inline-notice', 'role': 'status', 'aria-live': 'polite' });
			if (this.serviceMessage) {
				this.serviceNotice.className += this.serviceMessage.ok ? '' : ' em-notice-error';
				dom.content(this.serviceNotice, this.serviceMessage.text);
			}
			details.push(meshUI.details(_('Network details'), [
				E('div', { 'class': 'em-grid' }, [
					meshUI.card(_('Service status'), E('dl', { 'class': 'em-kv' }, services.map(function(service) {
						return [ E('dt', {}, service[1]), E('dd', {}, meshUI.badge(st[service[0]] === 'running' ? _('Running') : _('Stopped'), st[service[0]] === 'running' ? 'ok' : 'neutral')) ];
					}).reduce(function(a, b) { return a.concat(b); }, []).concat([
						E('dt', {}, _('Control connection')), E('dd', {}, meshUI.badge(st.socket === 'up' ? _('Ready') : _('Not ready'), st.socket === 'up' ? 'ok' : 'neutral'))
					]))),
					meshUI.card(_('Device details'), E('dl', { 'class': 'em-kv' }, [ E('dt', {}, _('AL MAC')), E('dd', {}, st.almac || '—'),
						E('dt', {}, _('Start at boot')), E('dd', {}, st.svc_enabled === '1' ? _('Enabled') : _('Disabled')) ]))
				]),
				E('div', { 'class': 'em-grid' }, [ meshUI.card(_('Backhaul link'), meshUI.output(st.bh_status)), meshUI.card(_('Topology'), meshUI.output(st.topology)) ]),
				meshUI.button(_('Restart EasyMesh'), function(ev) {
					return meshUI.busy(ev.currentTarget, function() {
						return callRestart().catch(function(e) { return { ok: false, error: e.message }; }).then(function(r) {
							self.serviceMessage = { ok: r.ok, text: r.ok ? _('Restart requested. Status will update automatically.') : (r.error || _('Restart failed.')) };
							return self.refresh();
						});
					});
				}, 'secondary', 'refresh'), this.serviceNotice
			]));
		}
		dom.content(this.detailsPanel, details);
		this.detailsPanel.querySelectorAll('details').forEach(function(n, i) { n.open = !!open[i]; });
	},

	render: function(data) {
		var self = this;
		this.panel = E('div');
		this.clientsPanel = E('div');
		this.detailsPanel = E('div');
		this.draw(data && data[0]);
		dom.content(this.clientsPanel, clientUI.render(data && data[1]));
		poll.add(function() { if (!document.hidden) return self.refresh(); }, 10);
		return meshUI.page('status', _('Mesh status and connected devices'), [ this.panel, this.clientsPanel, this.detailsPanel ], [
			meshUI.button(_('Refresh'), function(ev) { return meshUI.busy(ev.currentTarget, function() { return self.refresh(); }); }, 'secondary', 'refresh'),
			E('a', { 'class': 'em-button em-button-primary', 'href': L.url('admin', 'network', 'easymesh', 'onboarding') }, [ meshUI.icon('link'), _('Add node') ])
		]);
	}
});

'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require dom';
'require easymesh-mtk.ui as meshUI';

var calls = {
	get_uri: rpc.declare({ object: 'easymesh-mtk', method: 'get_uri', params: [ 'ifname' ], expect: { '': {} } }),
	action: rpc.declare({ object: 'easymesh-mtk', method: 'action', params: [ 'action', 'band', 'uri' ], expect: { '': {} } }),
	set: rpc.declare({ object: 'easymesh-mtk', method: 'set', params: [ 'key', 'value' ], expect: { '': {} } }),
	restart: rpc.declare({ object: 'easymesh-mtk', method: 'restart', expect: { '': {} } })
};

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() { return Promise.all([ uci.load('mapd'), uci.load('1905d_cfg') ]); },

	handleRpc: function(method, args) {
		return calls[method].apply(null, args || []).catch(function(e) { return { ok: false, error: e.message }; });
	},

	report: function(result, message, target) {
		var text = result.ok ? message : (result.error || _('Request failed.'));
		target = target || this.notice;
		if (target) {
			target.className = 'em-notice em-inline-notice ' + (result.ok ? 'em-notice-success' : 'em-notice-error');
			dom.content(target, text);
		} else ui.addNotification(null, E('p', {}, text), result.ok ? 'info' : 'error');
	},

	handleWps: function(ev) {
		var self = this;
		return meshUI.busy(ev.currentTarget, function() {
			return self.handleRpc('action', [ 'wps', 'all', '' ]).then(function(r) {
				self.report(r, _('WPS requested. Start WPS on the other node, then check Overview.'), self.wpsNotice);
			});
		});
	},

	handleDppUri: function(ev) {
		var self = this;
		return meshUI.busy(ev.currentTarget, function() {
			return self.handleRpc('get_uri', [ '' ]).then(function(r) {
				var out = document.getElementById('easymesh_dpp_uri');
				if (r.uri && out) { out.value = r.uri; if (self.copyButton) self.copyButton.disabled = false; }
				self.report(r.uri ? { ok: true } : { ok: false, error: r.error || _('No onboarding code available.') },
					_('Code generated. Copy it to the controller to add this node.'), self.dppNotice);
			});
		});
	},

	handleDppEnroll: function(ev) {
		var self = this, uri = ((document.getElementById('easymesh_dpp_uri') || {}).value || '').trim();
		if (!/^DPP:/.test(uri)) { this.report({ ok: false, error: _('Paste the agent onboarding code first.') }, '', this.dppNotice); return Promise.resolve(); }
		return meshUI.busy(ev.currentTarget, function() {
			return self.handleRpc('action', [ 'dpp_enroll', '', uri ]).then(function(r) {
				self.report(r, _('Node request accepted. Check Overview for the join result.'), self.dppNotice);
			});
		});
	},

	handleCopy: function(ev) {
		var self = this, out = document.getElementById('easymesh_dpp_uri');
		return meshUI.busy(ev.currentTarget, function() {
			var copy = navigator.clipboard && window.isSecureContext ? navigator.clipboard.writeText(out.value) : Promise.resolve().then(function() {
				out.focus(); out.select();
				if (!document.execCommand('copy')) throw new Error(_('Select and copy the code manually.'));
			});
			return copy.then(function() { self.report({ ok: true }, _('Onboarding code copied.'), self.dppNotice); })
				.catch(function(e) { self.report({ ok: false, error: e.message }, '', self.dppNotice); });
		});
	},

	handleRestart: function(ev) {
		var self = this;
		return meshUI.busy(ev.currentTarget, function() {
			return self.handleRpc('restart', []).then(function(r) { self.report(r, _('Restart requested. Check Overview for service status.')); });
		});
	},

	handlePresence: function(ev) {
		var self = this, select = ev.currentTarget, previous = this.presence;
		return meshUI.busy(select, function() {
			return self.handleRpc('set', [ 'presence_band_priority', select.value ]).then(function(r) {
				if (r.ok) self.presence = select.value; else select.value = previous;
				self.report(r, _('Band saved. Restart EasyMesh to apply.'), self.dppNotice);
			});
		});
	},

	render: function() {
		var self = this, role = uci.get('mapd', 'mapd_cfg', 'DeviceRole') || '2';
		var controller = role === '1', version = uci.get('1905d_cfg', 'map', 'map_ver') || 'R3';
		var enabled = uci.get('mapd', 'mapd_cfg', 'enable') === '1';
		this.presence = uci.get('mapd', 'dpp_cfg', 'presence_band_priority') || '5g';
		this.notice = E('div', { 'class': 'em-notice', 'role': 'status', 'aria-live': 'polite' });
		this.wpsNotice = E('div', { 'class': 'em-notice em-inline-notice', 'role': 'status', 'aria-live': 'polite' });
		this.dppNotice = E('div', { 'class': 'em-notice em-inline-notice', 'role': 'status', 'aria-live': 'polite' });
		if (!enabled) dom.content(this.notice, _('Enable EasyMesh in Settings'));
		var wpsButton = meshUI.button(_('Start WPS'), function(ev) { return self.handleWps(ev); }, 'primary', 'wifi');
		wpsButton.disabled = !enabled;
		var wps = meshUI.card(_('WPS quick pairing'), [
			E('div', { 'class': 'em-join-intro' }, [ meshUI.icon('wifi'), E('div', {}, [ E('h3', {}, _('Pair with one button')),
				E('p', {}, _('Use a visible 2.4 or 5 GHz network. WPS is unavailable on 6 GHz.')) ]) ]),
			E('ol', { 'class': 'em-steps' }, [ _('Enable Mesh on both nodes'), _('Start WPS on both nodes'), _('Check the connection in Overview') ].map(function(step) { return E('li', {}, step); })),
			wpsButton, this.wpsNotice
		]);
		var dppBody;
		if (version !== 'R3') dppBody = E('div', { 'class': 'em-notice' }, _('DPP requires MAP R3. Change the MAP version in Settings first.'));
		else {
			var field = E('textarea', { 'id': 'easymesh_dpp_uri', 'class': 'em-uri', 'rows': 4,
				'readonly': controller ? null : true, 'spellcheck': 'false', 'autocomplete': 'off',
				'placeholder': controller ? _('Paste the agent DPP code here') : _('Generate a code to share with the controller'),
				'aria-label': _('Onboarding code') });
			var actions = [];
			if (controller) actions.push(meshUI.button(_('Add node'), function(ev) { return self.handleDppEnroll(ev); }, 'primary', 'link'));
			else {
				actions.push(meshUI.button(_('Generate code'), function(ev) { return self.handleDppUri(ev); }, 'primary', 'link'));
				this.copyButton = meshUI.button(_('Copy code'), function(ev) { return self.handleCopy(ev); }, 'secondary', 'copy');
				this.copyButton.disabled = true;
				actions.push(this.copyButton);
			}
			if (!enabled) actions.forEach(function(button) { button.disabled = true; });
			dppBody = [ E('p', { 'class': 'em-note' }, controller ? _('Paste a code generated by the agent, then add the node.') :
				_('Generate a code on this node, then paste it on the controller.')),
				E('div', { 'class': 'em-field em-code-field' }, [ E('label', { 'for': 'easymesh_dpp_uri' }, _('Onboarding code')), field ]),
				E('div', { 'class': 'em-actions' }, actions), this.dppNotice ];
			if (!controller) dppBody.push(E('div', { 'class': 'em-field em-presence-field' }, [
				E('label', { 'for': 'em-presence' }, _('Discovery band')),
				E('select', { 'id': 'em-presence', 'change': function(ev) { return self.handlePresence(ev); } }, [
					[ '5g', '5 GHz' ], [ '2g', '2.4 GHz' ], [ '6g', '6 GHz' ]
				].map(function(band) { return E('option', { 'value': band[0], 'selected': band[0] === self.presence ? true : null }, band[1]); }))
			]));
		}
		return meshUI.page('onboarding', _('Connect another node to your Mesh'), [ this.notice, wps,
			meshUI.details(_('DPP code pairing'), dppBody, _('Use an onboarding code · MAP R3'))
		], [ meshUI.badge(meshUI.role(role), 'neutral'), meshUI.button(_('Restart'), function(ev) { return self.handleRestart(ev); }, 'secondary', 'refresh') ]);
	}
});

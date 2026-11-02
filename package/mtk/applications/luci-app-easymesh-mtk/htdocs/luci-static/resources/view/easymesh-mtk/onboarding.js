'use strict';
'require view';
'require rpc';
'require uci';
'require ui';

var calls = {
	get_uri: rpc.declare({ object: 'easymesh-mtk', method: 'get_uri', params: [ 'ifname' ], expect: { '': {} } }),
	action: rpc.declare({ object: 'easymesh-mtk', method: 'action', params: [ 'action', 'band', 'uri' ], expect: { '': {} } }),
	set: rpc.declare({ object: 'easymesh-mtk', method: 'set', params: [ 'key', 'value' ], expect: { '': {} } }),
	restart: rpc.declare({ object: 'easymesh-mtk', method: 'restart', expect: { '': {} } })
};

return view.extend({
	load: function() {
		return uci.load('mapd');
	},

	handleRpc: function(method, args) {
		return calls[method].apply(null, args || []).catch(function(e) {
			return { ok: false, error: e.message };
		});
	},

	report: function(res, okMessage) {
		if (res.ok)
			ui.addNotification(null, E('p', {}, okMessage), 'info');
		else
			ui.addNotification(null, E('p', {}, _('Failed: %s').format(res.error || _('unknown error'))), 'error');
	},

	handleWps: function(ev) {
		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;
		return this.handleRpc('action', [ 'wps', 'all', '' ])
			.then(L.bind(function(res) {
				btn.classList.remove('spinning');
				btn.disabled = false;
				this.report(res, _('WPS request accepted on %s. Check topology for the join result.').format(res.ifname || 'all radios'));
			}, this));
	},

	handleDppUri: function(ev) {
		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;
		return this.handleRpc('get_uri', [ '' ])
			.then(L.bind(function(res) {
				btn.classList.remove('spinning');
				btn.disabled = false;
				var out = document.getElementById('easymesh_dpp_uri');

				if (out)
					out.value = res.uri || '';

				this.report(res.uri ? { ok: true } : { ok: false, error: res.error || _('no DPP URI available') },
					_('DPP bootstrap URI retrieved, copy it to the controller.'));
			}, this));
	},

	handleDppEnroll: function(ev) {
		var uri = (document.getElementById('easymesh_dpp_uri') || {}).value || '';

		if (!/^DPP:/.test(uri.trim())) {
			ui.addNotification(null, E('p', {}, _('Paste a DPP URI (starting with "DPP:") first.')), 'warning');
			return;
		}

		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;
		return this.handleRpc('action', [ 'dpp_enroll', '', uri.trim() ])
			.then(L.bind(function(res) {
				btn.classList.remove('spinning');
				btn.disabled = false;
				this.report(res, _('DPP request accepted by the controller. Check topology for the join result.'));
			}, this));
	},

	handleRestart: function(ev) {
		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;
		return this.handleRpc('restart', [])
			.then(L.bind(function(res) {
				btn.classList.remove('spinning');
				btn.disabled = false;
				this.report(res, _('EasyMesh daemons are restarting, this may take a few seconds.'));
			}, this));
	},

	handlePresence: function(ev) {
		var select = ev.currentTarget;
		return this.handleRpc('set', [ 'presence_band_priority', select.value ])
			.then(L.bind(function(res) {
				this.report(res, _('DPP presence band saved. Restart EasyMesh to apply.'));
			}, this));
	},

	render: function() {
		var self = this;
		var role = uci.get('mapd', 'mapd_cfg', 'DeviceRole') || '2';
		var presence = uci.get('mapd', 'dpp_cfg', 'presence_band_priority') || '5g';

		var body = E([
			E('h3', {}, _('WPS push button')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Start WPS on both the controller and the agent. The agent scans 5 GHz first, ' +
				  'keep at least one non-hidden 2.4 GHz or 5 GHz fronthaul BSS for WPS.')),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': function(ev) { return self.handleWps(ev); }
				}, _('Start WPS push button'))
			]),

			E('h3', {}, _('DPP (Wi-Fi Easy Connect)')),
			E('p', { 'class': 'cbi-section-descr' },
				_('DPP requires MAP version R3. On the agent press "Retrieve DPP URI", then paste ' +
				  'that URI on the controller and press "Add DPP URI & start". Multiple URIs can be ' +
				  'added one after another.')),

			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('DPP presence band')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('select', { 'class': 'cbi-input-select', 'change': function(ev) { return self.handlePresence(ev); } },
						[ '5g', '2g' ].map(function(b) {
							return E('option', { 'value': b, 'selected': b === presence ? 'selected' : null },
								b === '5g' ? _('5 GHz first') : _('2.4 GHz first'));
						})),
					E('div', { 'class': 'cbi-value-description' },
						_('Band on which DPP presence announcements are sent. Takes effect after a restart.'))
				])
			]),

			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('DPP URI')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('textarea', {
						'id': 'easymesh_dpp_uri',
						'rows': 4,
						'style': 'width:100%',
						'placeholder': 'DPP:V:2;K:...'
					}),
					E('div', { 'class': 'cbi-value-description' },
						_('Current device role: %s').format(
							role === '1' ? _('Controller') : (role === '2' ? _('Agent') : _('Auto'))))
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) { return self.handleDppUri(ev); }
				}, _('Retrieve DPP URI')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': function(ev) { return self.handleDppEnroll(ev); }
				}, _('Add DPP URI & start'))
			]),

			E('h3', {}, _('Restart')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Re-run the MAP Turnkey bring-up script. Required after a device role or ' +
				  'MAP version change, and after changing more than four MBSS.')),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': function(ev) { return self.handleRestart(ev); }
				}, _('Restart EasyMesh'))
			])
		]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('EasyMesh onboarding')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Onboarding joins an agent to the mesh. Use WPS for a quick setup or DPP for a ' +
				  'secure QR-code based setup.')),
			body
		]);
	}
});

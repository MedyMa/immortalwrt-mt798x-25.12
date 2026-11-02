'use strict';
'require baseclass';
'require easymesh-mtk.ui as meshUI';

// The overview owns polling; this component only renders measured local data.
return baseclass.extend({
	renderSignalBar: function(value) {
		if (value == null || value === '' || !isFinite(Number(value))) return E('span', { 'class': 'em-label' }, '—');
		var rssi = Number(value), level = rssi >= -50 ? 4 : rssi >= -60 ? 3 : rssi >= -70 ? 2 : rssi >= -80 ? 1 : 0;
		return E('span', { 'class': 'em-rssi' }, [ E('span', { 'class': 'em-signal-bars' + (level <= 1 ? ' em-signal-weak' : level === 2 ? ' em-signal-fair' : ''), 'aria-hidden': 'true' },
			[ 1, 2, 3, 4 ].map(function(i) { return E('i', { 'class': i <= level ? 'is-on' : '' }); })), rssi + ' dBm' ]);
	},

	formatRate: function(value) {
		var number = parseFloat(value);
		return !isFinite(number) || number <= 0 ? '—' : number >= 1000 ? (number / 1000).toFixed(1) + ' Gbps' : number.toFixed(0) + ' Mbps';
	},

	renderType: function(client) {
		var tags = [];
		if (client.is_backhaul === 'Yes') tags.push(meshUI.badge(_('Backhaul'), 'neutral'));
		if (client.is_mlo === 'Yes') tags.push(meshUI.badge('MLO', 'accent'));
		return tags.length ? E('div', { 'class': 'em-health' }, tags) : E('span', { 'class': 'em-label' }, '—');
	},

	buildRows: function(clients) {
		var self = this;
		return clients.map(function(client) {
			var band = ({ '2.4G': '2.4 GHz', '5G': '5 GHz', '6G': '6 GHz' })[client.band] || client.band || '—';
			return E('tr', {}, [
				E('td', { 'data-label': _('Device') }, [ E('span', { 'class': 'em-client-name' }, client.hostname || client.ip || client.mac),
					E('span', { 'class': 'em-client-sub' }, (client.ip && client.hostname ? client.ip + ' · ' : '') + client.mac) ]),
				E('td', { 'data-label': _('Band') }, [ band, E('span', { 'class': 'em-client-sub' }, client.iface) ]),
				E('td', { 'data-label': _('Signal') }, self.renderSignalBar(client.signal)),
				// iw reports RX/TX from the AP's perspective; arrows describe the client.
				E('td', { 'data-label': _('Link rate') }, [ E('span', {}, '↓ ' + self.formatRate(client.tx_rate)),
					E('span', { 'class': 'em-client-sub' }, '↑ ' + self.formatRate(client.rx_rate)) ]),
				E('td', { 'data-label': _('Connection') }, self.renderType(client))
			]);
		});
	},

	render: function(result) {
		result = result || {};
		var valid = result && result.ok === true && Array.isArray(result.clients);
		var clients = valid ? result.clients : [];
		var body = !valid ? meshUI.empty(_('Unable to read clients'), result.error || _('Refresh to retry'), 'clients') : !clients.length ?
			meshUI.empty(_('No clients connected'), _('Connected devices will appear here.'), 'clients') : E('div', { 'class': 'em-scroll' }, [
				E('table', { 'class': 'em-client-table' }, [ E('thead', {}, E('tr', {}, [
					_('Device'), _('Band'), _('Signal'), _('Link rate'), _('Connection')
				].map(function(label) { return E('th', { 'scope': 'col' }, label); }))), E('tbody', {}, this.buildRows(clients)) ]) ]);
		return meshUI.card(_('Associated clients'), body, _('Local router only'),
			meshUI.badge(valid ? String(clients.length) : '—', 'neutral'));
	}
});

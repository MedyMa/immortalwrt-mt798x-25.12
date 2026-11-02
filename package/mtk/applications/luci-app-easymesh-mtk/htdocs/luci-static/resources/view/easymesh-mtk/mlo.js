'use strict';
'require view';
'require form';
'require uci';
'require easymesh-mtk.ui as meshUI';

return view.extend({
	load: function() {
		return uci.load('mapd');
	},

	render: function() {
		var wirelessLink = E('a', { 'class': 'em-button em-button-secondary', 'href': L.url('admin', 'network', 'wireless') },
			[ meshUI.icon('wifi'), _('Wireless MLO settings') ]);
		var ownership = E('div', { 'class': 'em-notice' }, _('Local MLO groups are managed under Network → Wireless. The profiles below are distributed to agents by the controller.'));
		if (uci.get('mapd', 'mapd_cfg', 'DeviceRole') !== '1') {
			this.handleSaveApply = null;
			this.handleSave = null;
			this.handleReset = null;
			return meshUI.page('mlo', _('Mesh profiles for agents'), [ ownership,
				meshUI.card(_('Mesh multi-link profiles'), meshUI.empty(_('Managed by the controller'), _('Configure distributed profiles on the controller. Agents receive their wireless settings from it.'), 'mlo'))
			], [ wirelessLink ]);
		}
		var m = new form.Map('mapd');
		var s = m.section(form.GridSection, 'iface', _('Node wireless profiles'));
		s.modaltitle = _('BSS profile');
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;
		var o = s.option(form.Value, 'ssid', _('SSID'));
		o.datatype = 'and(minlength(1),maxlength(32))';
		o.rmempty = false;
		o = s.option(form.ListValue, 'radio', _('Band'));
		o.value('8x', _('2.4 GHz'));
		o.value('11x', _('5 GHz low'));
		o.value('12x', _('5 GHz high'));
		o.value('13x', _('6 GHz'));
		o.textvalue = function(section_id) {
			return ({ '8x': '2.4 GHz', '11x': _('5 GHz low'), '12x': _('5 GHz high'), '13x': '6 GHz' })[uci.get('mapd', section_id, 'radio')] || '—';
		};
		o.rmempty = false;
		o = s.option(form.Value, 'mac', _('Radio MAC'));
		o.modalonly = true;
		o.default = 'ff:ff:ff:ff:ff:ff';
		o.datatype = 'macaddr';
		o.rmempty = false;
		o.description = _('The broadcast MAC applies the profile to every agent radio in this band.');
		o = s.option(form.ListValue, 'authmode', _('Authentication'));
		o.modalonly = true;
		o.value('0x0020', _('WPA2-PSK'));
		o.value('0x0040', _('WPA3-SAE'));
		o.value('0x0060', _('WPA2/WPA3 mixed'));
		o.default = '0x0060';
		o.rmempty = false;
		o = s.option(form.ListValue, 'EncryptType', _('Encryption'));
		o.modalonly = true;
		o.value('0x0008', 'AES');
		o.default = '0x0008';
		o.rmempty = false;
		o = s.option(form.Value, 'PSK', _('Password'));
		o.modalonly = true;
		o.password = true;
		o.datatype = 'wpakey';
		o.rmempty = false;
		o = s.option(form.Flag, 'bhbss', _('Backhaul BSS'));
		o.modalonly = true;
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.Flag, 'fhbss', _('Fronthaul BSS'));
		o.modalonly = true;
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.ListValue, 'hidden', _('Hide SSID'));
		o.modalonly = true;
		o.value('N', _('No'));
		o.value('Y', _('Yes'));
		o.default = 'N';
		o.rmempty = false;
		o = s.option(form.Value, 'mld_groupID', _('MLD group ID'));
		o.datatype = 'range(0,48)';
		o.default = '0';
		o.rmempty = false;
		o.description = _('0: off · 1–16: multi-link · 17–48: single-link');

		s = m.section(form.GridSection, 'bh_sta', _('Backhaul profiles'));
		s.modaltitle = _('Backhaul profile');
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;
		o = s.option(form.Value, 'almac', _('Agent AL MAC'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		o = s.option(form.Value, 'mlo_links', _('Number of links'));
		o.datatype = 'range(1,3)';
		o.default = '3';
		o.rmempty = false;
		o = s.option(form.Value, 'ruid_or_band', _('Radio IDs or bands'));
		o.placeholder = '8x 11x 13x';
		o.rmempty = false;
		o.description = _('Enter one radio MAC or band ID per link, separated by spaces.');

		return m.render().then(function(node) {
			return meshUI.page('mlo', _('Mesh profiles for agents'), [ ownership,
				meshUI.card(_('Controller profiles'), node, _('Leave profiles empty to follow local AP settings. Agents should be configured by the controller.'))
			], [ wirelessLink ]);
		});
	}
});

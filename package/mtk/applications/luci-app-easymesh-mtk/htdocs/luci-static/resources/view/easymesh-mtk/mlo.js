'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return Promise.all([ uci.load('mapd'), uci.load('wireless') ]);
	},

	render: function() {
		var wm = new form.Map('wireless', _('Local MLO groups'),
			_('Local APs use the same MLD group, SSID and security on all participating EHT radios. Applying changes disconnects associated stations.'));
		var s = wm.section(form.GridSection, 'wifi-iface');
		s.addremove = false;
		s.filter = function(section_id) {
			var device = uci.get('wireless', section_id, 'device');
			return uci.get('wireless', section_id, 'mode') === 'ap' && uci.get('wireless', device, 'type') === 'mtwifi';
		};
		var o = s.option(form.DummyValue, 'ssid', _('SSID'));
		o = s.option(form.DummyValue, 'device', _('Radio'));
		o = s.option(form.Value, 'mldgroup', _('MLD group ID'));
		o.datatype = 'range(0,16)';
		o.placeholder = '0';
		o.description = _('0 disables local MLO. Matching groups from 1 to 16 share one MLD.');

		var m = new form.Map('mapd', _('Controller BSS profiles'),
			_('The controller distributes these profiles to agents. With no entries, profiles are derived from the active local APs. Configure WPA2/WPA3 credentials before wireless onboarding.'));
		s = m.section(form.GridSection, 'iface', _('BSS profiles'));
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = false;
		o = s.option(form.Value, 'ssid', _('SSID'));
		o.datatype = 'and(minlength(1),maxlength(32))';
		o.rmempty = false;
		o = s.option(form.ListValue, 'radio', _('Band'));
		o.value('8x', _('2.4 GHz'));
		o.value('11x', _('5 GHz low'));
		o.value('12x', _('5 GHz high'));
		o.value('13x', _('6 GHz'));
		o.rmempty = false;
		o = s.option(form.Value, 'mac', _('Radio MAC'));
		o.default = 'ff:ff:ff:ff:ff:ff';
		o.datatype = 'macaddr';
		o.rmempty = false;
		o.description = _('The broadcast MAC applies the profile to every agent radio in this band.');
		o = s.option(form.ListValue, 'authmode', _('Authentication'));
		o.value('0x0020', _('WPA2-PSK'));
		o.value('0x0040', _('WPA3-SAE'));
		o.value('0x0060', _('WPA2/WPA3 mixed'));
		o.default = '0x0060';
		o.rmempty = false;
		o = s.option(form.ListValue, 'EncryptType', _('Encryption'));
		o.value('0x0008', 'AES');
		o.default = '0x0008';
		o.rmempty = false;
		o = s.option(form.Value, 'PSK', _('Password'));
		o.password = true;
		o.datatype = 'wpakey';
		o.rmempty = false;
		o = s.option(form.Flag, 'bhbss', _('Backhaul BSS'));
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.Flag, 'fhbss', _('Fronthaul BSS'));
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.ListValue, 'hidden', _('Hide SSID'));
		o.value('N', _('No'));
		o.value('Y', _('Yes'));
		o.default = 'N';
		o.rmempty = false;
		o = s.option(form.Value, 'mld_groupID', _('Distributed MLD group ID'));
		o.datatype = 'range(0,48)';
		o.default = '0';
		o.rmempty = false;
		o.description = _('0 disables grouping; groups 1–16 are multi-link and 17–48 are single-link profiles. Members of a multi-link group need matching SSID and security.');

		s = m.section(form.GridSection, 'bh_sta', _('Agent backhaul MLD profiles'));
		s.anonymous = true;
		s.addremove = true;
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

		return Promise.all([ wm.render(), m.render() ]).then(function(nodes) {
			return E('div', {}, nodes);
		});
	}
});

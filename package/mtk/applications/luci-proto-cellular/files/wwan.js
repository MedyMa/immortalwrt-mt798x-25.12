'use strict';
'require form';
'require network';

return network.registerProtocol('wwan', {
	getI18n: function() {
		return _('Automatic') + ' USB WWAN';
	},

	getPackageName: function() {
		return 'wwan';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	renderFormOptions: function(s) {
		var o;

		o = s.taboption('general', form.Value, 'bus', _('USB device'), _('Leave empty for automatic detection.'));
		o.placeholder = _('Automatic');

		o = s.taboption('general', form.Value, 'apn', _('APN'));
		o.validate = function(section_id, value) {
			return !value || /^[a-zA-Z0-9.-]+$/.test(value) || _('Invalid APN provided');
		};

		o = s.taboption('general', form.Value, 'pincode', _('PIN'));
		o.datatype = 'and(uinteger,minlength(4),maxlength(8))';

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication Type'));
		o.value('none', _('None'));
		o.value('pap', 'PAP');
		o.value('chap', 'CHAP');
		o.value('both', 'PAP/CHAP');
		o.default = 'none';

		o = s.taboption('general', form.Value, 'username', _('PAP/CHAP username'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.depends('auth', 'both');

		o = s.taboption('general', form.Value, 'password', _('PAP/CHAP password'));
		o.password = true;
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.depends('auth', 'both');

		o = s.taboption('advanced', form.Value, 'delay', _('Modem init timeout'));
		o.datatype = 'uinteger';

		// Accepted by the WWAN dispatcher and used by its QMI backend.
		o = s.taboption('advanced', form.Value, 'modes', _('Modem network modes'));
	}
});

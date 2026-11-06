'use strict';
'require network';

return network.registerProtocol('rmnet6', {
	getI18n: function() {
		return 'RMNET (IPv6)';
	},

	getPackageName: function() {
		return 'quectel-CM-5G';
	},

	// Keep the same physical-device semantics as the rmnet6 netifd handler.
	renderFormOptions: function(s) {}
});

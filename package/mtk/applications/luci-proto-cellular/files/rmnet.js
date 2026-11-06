'use strict';
'require network';

return network.registerProtocol('rmnet', {
	getI18n: function() {
		return 'RMNET (IPv4)';
	},

	getPackageName: function() {
		return 'quectel-CM-5G';
	},

	// The vendor connection manager supplies addresses, DNS and routes.
	// netifd accepts an assigned device, but no APN/authentication options.
	renderFormOptions: function(s) {}
});

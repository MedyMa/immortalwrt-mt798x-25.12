-- SPDX-License-Identifier: GPL-2.0-only
-- Run with Lua 5.1, lua-cjson, libuci-lua and nixio. No router is contacted.
-- Usage: lua runtime.lua SOURCE_ROOT EMPTY_TEST_DIRECTORY
local source, root = assert(arg[1]), assert(arg[2])
local fs, nixio, uci = require "nixio.fs", require "nixio", require "uci"
local json = require "cjson"
assert(not fs.access(root), "test directory must not exist")
assert(root:sub(1, 1) == "/" and #root > 10, "absolute test directory required")
fs.mkdirr(root)
local function mapped(path)
	if type(path) == "string" and (path:match("^/etc/") or path:match("^/sys/") or path:match("^/var/run/") or path:match("^/tmp/dhcp") or path:match("^/tmp/wapp") or path:match("^/tmp/1905") or path:match("^/tmp/mapd_ctrl")) then return root .. path end
	return path
end
for _, name in ipairs({ "access", "stat", "readfile", "writefile", "mkdir", "mkdirr", "dir", "unlink", "chmod" }) do
	local original = fs[name]
	fs[name] = function(path, ...) return original(mapped(path), ...) end
end
local rename, open, io_open, cursor = fs.rename, nixio.open, io.open, uci.cursor
fs.rename = function(a, b) return rename(mapped(a), mapped(b)) end
nixio.open = function(path, ...) return open(mapped(path), ...) end
io.open = function(path, ...) return io_open(mapped(path), ...) end
fs.mkdirr("/etc/config"); fs.mkdirr(root .. "/saved")
uci.cursor = function() return cursor(root .. "/etc/config", root .. "/saved") end
local function write(path, data)
	fs.mkdirr(mapped(path):match("^(.+)/[^/]+$"))
	assert(fs.writefile(path, data))
end
local function add_section(c, config, kind, name, values)
	assert(c:set(config, name, kind))
	for key, value in pairs(values) do assert(c:set(config, name, key, value)) end
end
local io_popen = io.popen
io.popen = function(cmd, ...)
	if cmd == "ls /etc/wireless/" then return io_popen("ls " .. root .. "/etc/wireless/", ...) end
	return io_popen(cmd, ...)
end
local count = 0
local function expect(value, label)
	assert(value, label)
	count = count + 1
	print("ok " .. count .. " - " .. label)
end
local function reject(fn, label)
	local ok = pcall(fn)
	expect(not ok, label)
end
package.path = source .. "/package/mtk/applications/mtwifi-cfg/files/l1util/?.lua;" .. package.path
local mesh = dofile(source .. "/package/mtk/applications/mapd/files/easymesh.lua")
package.loaded["mtk.easymesh"] = mesh
local real_exec = mesh.exec
local ok, output = real_exec({ "/bin/echo", "$(printf injected); 'quoted'" })
expect(ok and output:find("$(printf injected); 'quoted'", 1, true), "commands preserve literal arguments")
expect(not real_exec({ "/bin/false" }), "command failure is preserved")
expect(not real_exec({ "/bin/sleep", "2" }, 0.1), "command timeout is preserved")
reject(function() mesh.scalar("bad\nvalue") end, "line break rejected")
expect(not mesh.ifname("pci/0000:01:00.0") and mesh.ifname("rai0"), "interface validation excludes hardware paths")
expect(not mesh.mac("not-a-mac") and mesh.mac("02:10:20:30:40:50"), "MAC syntax validated")

mesh.defaults()
local c = uci.cursor()
expect(c:get("mapd", "mapd_cfg") == "mapd_cfg" and c:get("1905d_cfg", "map") == "iface", "clean install creates named sections")
expect(c:get("mapd", "mapd_cfg", "enable") == "0", "clean install leaves mesh disabled")
expect(c:get("mapd", "mapd_cfg", "DhcpCtl") == "0", "clean install retains network ownership")
expect(c:get("1905d_cfg", "map", "almac") == nil, "no shared hardcoded AL MAC")
local before = fs.readfile("/etc/config/mapd")
mesh.defaults()
expect(fs.readfile("/etc/config/mapd") == before, "defaults are idempotent")

write("/etc/wireless/l1profile.dat", [[
INDEX0=MT7990
INDEX0_main_ifname=ra0;rai0
INDEX0_ext_ifname=ra;rai
INDEX0_apcli_ifname=apcli;apclii
INDEX0_wds_ifname=wds;wdsi
INDEX0_mesh_ifname=mesh;meshi
INDEX0_profile_path=/etc/wireless/b0.dat;/etc/wireless/b1.dat
INDEX1=MT7990
INDEX1_main_ifname=rax0
INDEX1_ext_ifname=rax
INDEX1_apcli_ifname=apclix
INDEX1_wds_ifname=wdsx
INDEX1_mesh_ifname=meshx
INDEX1_profile_path=/etc/wireless/b2.dat
]])
write("/etc/config/wireless", [[
config wifi-device 'MT7990_1_1'
 option type 'mtwifi'
 option path 'platform/11280000.pcie/pci0000:00/0000:00:00.0'
 option band '2g'
 option map_mode '1'
config wifi-device 'MT7990_1_2'
 option type 'mtwifi'
 option band '5g'
 option map_mode '1'
config wifi-device 'MT7990_2'
 option type 'mtwifi'
 option band '6g'
 option map_mode '1'
config wifi-iface 'ap0'
 option device 'MT7990_1_1'
 option mode 'ap'
 option network 'lan'
 option ssid 'Mesh 2G'
 option encryption 'sae-mixed'
 option key 'safe passphrase'
config wifi-iface 'ap1'
 option device 'MT7990_1_2'
 option mode 'ap'
 option network 'lan'
 option ssid 'Mesh 5G'
 option encryption 'psk2'
 option key 'safe passphrase'
config wifi-iface 'ap2'
 option device 'MT7990_2'
 option mode 'ap'
 option network 'lan'
 option ssid 'Mesh 6G'
 option encryption 'sae'
 option key 'safe passphrase'
]])
for _, name in ipairs({ "ra0", "rai0", "rax0", "apcli0", "apclii0", "apclix0" }) do
	write("/sys/class/net/" .. name .. "/flags", "0x1003\n")
	fs.mkdirr("/sys/class/net/" .. name .. "/phy80211")
end
for i = 0, 2 do write("/etc/wireless/b" .. i .. ".dat", "MapMode=1\n") end
local interfaces = mesh.interfaces()
expect(#interfaces == 3 and interfaces[1].ifname == "ra0" and interfaces[3].ifname == "rax0", "all BE14 bands resolve through L1 profile")
expect(interfaces[1].ifname ~= "platform/11280000.pcie/pci0000:00/0000:00:00.0", "PCI paths are never control interfaces")
c = uci.cursor(); c:set("mapd", "mapd_cfg", "enable", "1"); c:commit("mapd")
expect(mesh.configure(), "agent creates managed backhaul STAs")
expect(not mesh.configure(), "backhaul configuration is idempotent")
interfaces = mesh.interfaces()
expect(#interfaces == 6 and interfaces[6].ifname == "apclix0", "agent has one bSTA per radio")
c = uci.cursor(); c:set("mapd", "mapd_cfg", "DeviceRole", "1"); c:commit("mapd")
expect(mesh.configure(), "controller disables automatically created bSTAs")
c = uci.cursor()
expect(c:get("wireless", "map_bsta_MT7990_1_1", "disabled") == "1", "controller bSTA is disabled")
c:set("wireless", "map_bsta_MT7990_1_1", "mapd_managed", "0"); c:set("wireless", "map_bsta_MT7990_1_1", "ssid", "user backhaul"); c:commit("wireless")
mesh.configure(); c = uci.cursor()
expect(c:get("wireless", "map_bsta_MT7990_1_1", "ssid") == "user backhaul", "user backhaul configuration is retained")

write("/etc/config/network", "config interface 'wan'\n option device 'eth2'\n")
write("/etc/config/dhcp", "config dhcp 'lan'\n option ignore '0'\n")
write("/sys/class/net/br-lan/address", "02:10:20:30:40:50\n")
fs.mkdirr("/sys/class/net/br-lan/bridge")
for _, port in ipairs({ "lan0", "lan1", "ra0" }) do fs.mkdirr("/sys/class/net/br-lan/brif/" .. port) end
write("/etc/map/mapd_default.cfg", "DeviceRole=2\nmode=1\nSteerEnable=1\n")
write("/etc/map/mapd_user.cfg", "\nSteerEnable=0\nBhPriority2G=2\n")
write("/etc/map/1905d.cfg", "map_agent=1\nmap_root=0\nmap_agent_alid=00:11:22:33:44:55\nlan=eth0\n")
write("/etc/ethernet_cfg.txt", "lan_vid=1;\nwan_vid=2;\n")
write("/etc/wapp_ap_ra0_default.conf", "interface=ra0\ninterworking=1\n")
local commands = {}
mesh.exec = function(argv)
	commands[#commands + 1] = argv
	if argv[1] == "/bin/ubus" then return true, '{"up":true,"l3_device":"br-lan"}' end
	return true, "OK\n"
end
local network_before, dhcp_before = fs.readfile("/etc/config/network"), fs.readfile("/etc/config/dhcp")
expect(mesh.prepare(), "controller runtime configuration generated")
local state = mesh.read_json(mesh.state_path)
expect(state.almac == "02:10:20:30:40:50" and state.bridge == "br-lan", "AL MAC and bridge come from running LAN")
local mapcfg = fs.readfile("/etc/map/mapd_cfg")
expect(mapcfg:find("lan_interface=lan0 lan1", 1, true) and not mapcfg:find("lan_interface=eth2", 1, true), "LAN ports do not include unbridged WAN")
expect(mapcfg:find("SteerEnable=1", 1, true), "current UI settings override stale user mirrors")
expect(fs.readfile("/etc/map/1905d.cfg"):find("map_root=1", 1, true), "controller role reaches 1905 configuration")
expect(fs.readfile("/etc/dpp_cfg.txt"):find("allowed_role=2", 1, true), "controller role reaches DPP configuration")
expect(network_before == fs.readfile("/etc/config/network") and dhcp_before == fs.readfile("/etc/config/dhcp"), "preparation leaves networking and DHCP unchanged")
c = uci.cursor(); c:set("wireless", "ap0", "network", "guest"); c:commit("wireless")
reject(mesh.prepare, "guest networks are not silently enrolled into the mesh LAN")
c = uci.cursor(); c:set("wireless", "ap0", "network", { "lan", "guest" }); c:commit("wireless")
reject(mesh.prepare, "mixed LAN and guest membership requires explicit traffic separation")
c = uci.cursor(); c:set("wireless", "ap0", "network", { "lan" }); c:commit("wireless")
expect(mesh.prepare(), "single LAN UCI list membership is supported")
local wts = fs.readfile("/etc/map/wts_bss_info_config")
expect(wts:find("Mesh\\ 2G", 1, true) and wts:find("safe\\ passphrase", 1, true), "BSS token escaping preserves spaces")
expect(wts:find("13x", 1, true) and wts:find("mld_groupID 0 \n", 1, true), "6 GHz and MLD delimiter are serialized")
expect(fs.stat("/etc/map/wts_bss_info_config", "modestr") == "rw-------", "credential file permissions are private")
c = uci.cursor(); c:set("mapd", "mapd_cfg", "DeviceRole", "2"); c:commit("mapd"); mesh.prepare()
expect(fs.readfile("/etc/map/1905d.cfg"):find("map_agent=1", 1, true) and fs.readfile("/etc/dpp_cfg.txt"):find("allowed_role=1", 1, true), "agent role reaches both daemons")
c = uci.cursor(); c:set("1905d_cfg", "map", "map_ver", "R5"); c:commit("1905d_cfg")
reject(mesh.prepare, "unsupported MAP version rejected")
c = uci.cursor(); c:set("1905d_cfg", "map", "map_ver", "R3"); c:commit("1905d_cfg")
write("/etc/wireless/b0.dat", "MapMode=0\n")
reject(mesh.prepare, "stale driver mode detected")
write("/etc/wireless/b0.dat", "MapMode=1\n")
c = uci.cursor(); c:set("1905d_cfg", "map", "almac", "ff:ff:ff:ff:ff:ff"); c:commit("1905d_cfg")
reject(mesh.prepare, "multicast AL MAC rejected")
c = uci.cursor(); c:delete("1905d_cfg", "map", "almac"); c:commit("1905d_cfg")
add_section(c, "mapd", "iface", "bss_a", { mac = "ff:ff:ff:ff:ff:ff", radio = "8x", ssid = 'Quoted "SSID"', PSK = "secret with space", authmode = "0x0020", EncryptType = "0x0008", bhbss = "1", fhbss = "1", mld_groupID = "1" })
add_section(c, "mapd", "iface", "bss_b", { mac = "ff:ff:ff:ff:ff:ff", radio = "11x", ssid = "Different SSID", PSK = "secret with space", authmode = "0x0020", EncryptType = "0x0008", bhbss = "1", fhbss = "1", mld_groupID = "1" }); c:commit("mapd")
reject(mesh.prepare, "inconsistent distributed MLD groups rejected")
c = uci.cursor(); c:set("mapd", "bss_b", "ssid", 'Quoted "SSID"'); c:commit("mapd")
expect(mesh.prepare(), "matching distributed MLD group accepted")

local rpc_path = source .. "/package/mtk/applications/luci-app-easymesh-mtk/root/usr/libexec/rpcd/easymesh-mtk"
local function rpc(method, params, positional)
	local saved_arg, saved_read, saved_write = arg, io.read, io.write
	local replies = {}
	arg = { "call", method }
	for _, value in ipairs(positional or {}) do arg[#arg + 1] = value end
	io.read = function() return json.encode(params or {}) end
	io.write = function(...) for _, value in ipairs({ ... }) do replies[#replies + 1] = tostring(value) end end
	local ok, why = pcall(dofile, rpc_path)
	arg, io.read, io.write = saved_arg, saved_read, saved_write
	assert(ok, why)
	local raw = table.concat(replies)
	return json.decode(raw), raw
end
commands = {}
mesh.exec = function(argv)
	commands[#commands + 1] = argv
	if argv[1] == "/usr/bin/pgrep" then return false, "" end
	if argv[1] == "/usr/bin/mapd_cli" and argv[3] == "get_dpp_uri" then return true, 'DPP URI: DPP:V:2;K:abc123;;\n' end
	return true, "OK\n"
end
local reply = rpc("get_status")
expect(reply.enable == "1" and not reply.running and reply.mapd == "stopped", "enabled configuration is not reported as running")
reply = rpc("set", { key = "DeviceRole", value = "1" })
expect(reply.ok and uci.cursor():get("mapd", "mapd_cfg", "DeviceRole") == "1", "rpcd stdin JSON arguments reach UCI")
reply = rpc("set", {}, { "DeviceRole", "2" })
expect(reply.ok and uci.cursor():get("mapd", "mapd_cfg", "DeviceRole") == "2", "legacy positional CLI remains compatible")
expect(not rpc("set", { key = "SteerEnable", value = "2" }).ok, "invalid boolean rejected by RPC")
expect(not rpc("set", { key = "APSteerRssiTh", value = "-101" }).ok, "RSSI range checked by RPC")
expect(not rpc("set", { key = "BhPriority2G", value = "1.5" }).ok, "fractional priority rejected by RPC")
expect(not rpc("set", { key = "map_ver", value = "R5" }).ok, "unbuilt MAP version rejected by RPC")
expect(not rpc("set", { key = "unknown", value = "$(touch /tmp/injected)" }).ok, "unknown RPC keys rejected")
expect(not rpc("set", { key = "SteerEnable", value = 1 }).ok, "parameter types checked before command execution")
expect(not rpc("set", { key = "DeviceRole", value = "1\n2" }).ok, "RPC line injection rejected")
expect(not rpc("set", { key = "DeviceRole", value = "1", extra = "ignored" }).ok, "undeclared RPC parameters rejected")
local result, raw = rpc("get_clients")
expect(result.ok and raw:find('"clients":%[%]'), "empty client list is a JSON array")
write("/tmp/dhcp.leases", '1 12:34:56:78:9a:bc 192.168.1.22 quote"host *\n')
mesh.exec = function(argv)
	commands[#commands + 1] = argv
	if argv[1] == "/usr/sbin/iw" and argv[3] == "ra0" then
		return true, 'Station 12:34:56:78:9a:bc (on ra0)\n\tsignal: -53 dBm\n\trx bitrate: 1201.0 MBit/s\n\ttx bitrate: 2402.0 MBit/s\n\tmld address: 22:33:44:55:66:77\n'
	elseif argv[1] == "/usr/sbin/iw" then return true, "" end
	return true, "OK\n"
end
result, raw = rpc("get_clients")
expect(result.scope == "local" and #result.clients == 1 and result.clients[1].hostname == 'quote"host', "client JSON escapes hostnames and identifies local scope")
expect(result.clients[1].rx_rate == "1201.0" and result.clients[1].signal == "-53" and result.clients[1].is_mlo == "Yes", "client counters preserve measured station fields")
expect(result.clients[1].is_backhaul == "Unknown", "unmeasured backhaul identity is not fabricated")
local working_exec = mesh.exec
mesh.exec = function(argv)
	if argv[1] == "/usr/sbin/iw" and argv[3] == "ra0" then return true, "Station 12:34:56:78:9a:bc (on ra0)\n" end
	return true, ""
end
result = rpc("get_clients")
expect(result.clients[1].signal == "" and result.clients[1].is_mlo == "Unknown", "missing station measurements stay unknown")
mesh.exec = function() return false, "iw failed" end
expect(not rpc("get_clients").ok, "station query failure is not reported as an empty client list")
mesh.exec = working_exec
expect(not rpc("get_uri", { ifname = "pci/invalid" }).ok, "RPC URI interface must resolve to an active netdev")
expect(not rpc("action", { action = "wps", band = "6g", uri = "" }).ok, "WPS rejects the 6 GHz band")
expect(not rpc("action", { action = "dpp_enroll", uri = "DPP:K:test;;" }).ok, "DPP URI enrolment requires controller role")
mesh.exec = function() return false, "control command failed" end
expect(not rpc("action", { action = "wps", band = "5g", uri = "" }).ok, "failed control command is not reported as success")

-- Exercise driver option mapping from the actual converter without loading a
-- radio or issuing driver commands.
local cfg_file = assert(io_open(source .. "/package/mtk/applications/mtwifi-cfg/files/mtwifi-cfg/mtwifi_cfg", "r"))
local cfg_source = cfg_file:read("*a"); cfg_file:close()
local map_function = assert(cfg_source:match("function set_map_cfg%(cfg, dats%).-\nend"))
local env = setmetatable({ nixio = { syslog = function() end }, set_dev_dat = function(dats, key, value)
	dats[key] = type(value) == "boolean" and (value and 1 or 0) or value
end }, { __index = _G })
local chunk = assert(loadstring(map_function .. "\nreturn set_map_cfg")); setfenv(chunk, env)
local apply_map = chunk(); local dat = {}
expect(apply_map({ config = { map_mode = 1, SRMode = true, MapBalance = false } }, dat) and dat.MapMode == "1" and dat.SRMode == 1 and dat.MapBalance == 0, "netifd MAP and boolean parameters reach DAT")
expect(apply_map({ config = {} }, dat) and dat.MapMode == "0", "unset MAP mode defaults to disabled")
expect(not apply_map({ config = { map_mode = "invalid" } }, dat), "invalid driver MAP mode rejected")

mesh.exec = function(argv)
	commands[#commands + 1] = argv
	if argv[1] == "/usr/bin/mapd_cli" and argv[3] == "get_dpp_uri" then return true, "DPP URI: DPP:V:2;K:public;;\n" end
	return true, "OK\n"
end
local uri_reply = rpc("get_uri", { ifname = "ra0" })
expect(uri_reply.ok and uri_reply.uri == "DPP:V:2;K:public;;", "DPP URI reply is parsed from daemon output")
local started, dpp_type = false, false
for _, argv in ipairs(commands) do
	if argv[1] == "/usr/bin/wappctrl" and argv[4] == "dpp_start" then started = true end
	if argv[1] == "/usr/bin/wappctrl" and argv[4] == "dpp_onboard_type" and argv[5] == "type=1" then dpp_type = true end
end
expect(started, "agent URI retrieval requests presence announcements")
expect(dpp_type, "DPP onboarding uses the driver's type=value command syntax")

c = uci.cursor();c:set("wireless", "map_bsta_MT7990_1_2", "disabled", "0");c:commit("wireless")
write("/var/run/wpa_supplicant/wpa_supplicant-apclii0.conf", 'update_config=1\nnetwork={\n ssid="saved mesh"\n psk="saved=password"\n}\n')
expect(mesh.save_backhaul("apclii0"), "managed backhaul credentials are saved")
expect(fs.readfile("/etc/map/backhaul-apclii0.conf"):find('saved=password', 1, true) and fs.stat("/etc/map/backhaul-apclii0.conf", "modestr") == "rw-------", "backhaul recovery file preserves secrets with private permissions")
local saved = fs.readfile("/etc/map/backhaul-apclii0.conf")
mesh.exec = function() return true, "FAIL\n" end
reject(function() mesh.save_backhaul("apclii0") end, "failed SAVE_CONFIG reply is rejected")
expect(fs.readfile("/etc/map/backhaul-apclii0.conf") == saved, "failed save leaves existing credentials intact")
mesh.exec = function(argv) commands[#commands + 1] = argv;return true, "OK\n" end
write("/var/run/hostapd/hostapd-ra0.conf", 'interface=ra0\nssid=learned mesh\nwpa=2\nwpa_key_mgmt=WPA-PSK\nwpa_passphrase=learned=password\nmulti_ap=3\nbss=ra9\nssid=wrong BSS\nwpa_passphrase=wrong-password\n')
expect(mesh.save_ap("ra0"), "agent AP configuration is persisted")
c=uci.cursor()
expect(c:get("wireless", "ap0", "ssid") == "learned mesh" and c:get("wireless", "ap0", "key") == "learned=password", "AP save scopes the correct BSS and preserves equals signs")
write("/sys/class/net/ra0/phy80211/name", "phy7\n")
write("/var/run/hostapd-ra0.conf", 'interface=ra0\ndriver=nl80211\nssid=learned mesh\nwpa=2\nwpa_key_mgmt=WPA-PSK\nwpa_passphrase=learned=password\nbss=ra9\nssid=other mesh\n')
expect(mesh.add_bss("ra1"), "controller-created BSS uses native hostapd adapter")
c=uci.cursor()
expect(c:get("wireless", "map_ap_ra1", "device") == "MT7990_1_1" and c:get("wireless", "map_ap_ra1", "ssid") == "learned mesh", "dynamic BSS is registered in persistent wireless configuration")
local new_cfg = fs.readfile("/var/run/hostapd/hostapd-ra1.conf")
expect(new_cfg:find("interface=ra1", 1, true) and not new_cfg:find("bss=ra9", 1, true), "dynamic BSS has a dedicated configuration block")
local right_phy=false
for _, argv in ipairs(commands) do if argv[1] == "/usr/sbin/hostapd_cli" and argv[6] == "bss_config=phy7:/var/run/hostapd/hostapd-ra1.conf" then right_phy=true end end
expect(right_phy, "dynamic BSS uses the registered PHY rather than assumed probe order")
reject(function() mesh.add_bss("ra5") end, "sparse dynamic AP slot rejected before configuration changes")
write("/sys/class/net/ra1/flags", "0x1003\n")
write("/sys/class/net/ra1/phy80211/name", "phy7\n")
commands = {}
expect(rpc("action", { action = "wps", band = "all", uri = "" }).ok, "WPS control commands accepted on eligible bands")
local pbc, wps_type = 0, 0
for _, argv in ipairs(commands) do
	if argv[1] == "/usr/bin/wappctrl" and argv[3] == "wps_pbc" then pbc = pbc + 1 end
	if argv[1] == "/usr/bin/wappctrl" and argv[4] == "dpp_onboard_type" and argv[5] == "type=0" then wps_type = wps_type + 1 end
end
expect(pbc == 2, "WPS runs once per participating 2.4/5 GHz radio")
expect(wps_type == 2, "WPS resets DPP onboarding mode on each participating radio")
c = uci.cursor(); c:set("mapd", "mapd_cfg", "network", "mesh"); c:commit("mapd")
expect(mesh.configure(), "changing the selected LAN updates managed backhaul configuration")
c = uci.cursor()
expect(c:get("wireless", "map_bsta_MT7990_1_2", "network") == "mesh" and c:get("wireless", "map_bsta_MT7990_1_1", "network") == "lan", "only managed bSTAs follow a LAN change")
print("1.." .. count)

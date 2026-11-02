-- SPDX-License-Identifier: GPL-2.0-only
-- Adapter for the mtwifi-cfg/netifd backend. Never reconfigure LAN/WAN or DHCP.
local M = {}
local uci = require "uci"
local nixio = require "nixio"
local fs = require "nixio.fs"
local json = require "cjson"
local l1 = require "l1dat_parser"
M.json = json
M.state_path = "/var/run/easymesh/platform.json"

local function check(value, message)
	assert(value, message)
	return value
end

function M.scalar(value)
	check(type(value) == "string" or type(value) == "number", "invalid configuration value")
	value = tostring(value)
	check(not value:find("[%z\r\n]"), "configuration contains a line break")
	return value
end

function M.ifname(value)
	return type(value) == "string" and #value > 0 and #value <= 15 and value:match("^[%w_.:%-]+$") ~= nil
end

function M.mac(value)
	return type(value) == "string" and value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

function M.exec(argv, seconds)
	local reader, writer = nixio.pipe()
	check(reader and writer, "cannot create command pipe")
	local pid = check(nixio.fork(), "cannot fork command")
	if pid == 0 then
		reader:close()
		local input = nixio.open("/dev/null", "r")
		nixio.dup(input, nixio.stdin)
		nixio.dup(writer, nixio.stdout)
		nixio.dup(writer, nixio.stderr)
		input:close()
		writer:close()
		nixio.execp("timeout", tostring(seconds or 5), unpack(argv))
		os.exit(127)
	end
	writer:close()
	local chunks, count = {}, 0
	while true do
		local part = reader:read(4096)
		if not part or #part == 0 then break end
		if count < 65536 then
			chunks[#chunks + 1] = part:sub(1, 65536 - count)
			count = count + #part
		end
	end
	reader:close()
	local _, reason, code = nixio.waitpid(pid)
	return reason == "exited" and code == 0, table.concat(chunks)
end

function M.read_json(path)
	local ok, value = pcall(json.decode, fs.readfile(path) or "")
	return ok and type(value) == "table" and value or nil
end

function M.atomic(path, data)
	local tmp = path .. "." .. nixio.getpid()
	local file = check(nixio.open(tmp, "w", "600"), "cannot write " .. path)
	local ok = file:writeall(data)
	file:close()
	if not ok or not fs.rename(tmp, path) then
		fs.unlink(tmp)
		error("cannot replace " .. path)
	end
end

local function flat(path)
	local result = {}
	for line in (fs.readfile(path) or ""):gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key then result[key] = value end
	end
	return result
end

local function merge(target, source)
	for key, value in pairs(source or {}) do
		if key:match("^[%w_]+$") and type(value) ~= "table" and not key:match("^%.") then
			target[key] = M.scalar(value)
		end
	end
	return target
end

local function flat_text(values)
	local keys, lines = {}, {}
	for key in pairs(values) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do lines[#lines + 1] = key .. "=" .. M.scalar(values[key]) end
	return table.concat(lines, "\n") .. "\n"
end

local function section(c, config, name, kind, values)
	check(c:set(config, name, kind), "cannot create " .. config .. "." .. name)
	for key, value in pairs(values or {}) do check(c:set(config, name, key, value), "cannot set " .. key) end
end

function M.defaults()
	fs.mkdirr("/etc/config")
	for _, name in ipairs({ "mapd", "1905d_cfg" }) do
		if not fs.access("/etc/config/" .. name) then M.atomic("/etc/config/" .. name, "") end
	end
	local c = uci.cursor()
	for _, entry in ipairs({ { "mapd", "mapd_cfg" }, { "mapd", "mapd_user" },
		{ "mapd", "mapd_strng" }, { "mapd", "dpp_cfg" }, { "1905d_cfg", "map", "iface" } }) do
		if not c:get(entry[1], entry[2]) then section(c, entry[1], entry[2], entry[3] or entry[2]) end
	end
	local defaults = { enable = c:get("mapd", "mapd_cfg", "Enable") or "0", network = "lan",
		DeviceRole = "2", mode = "1", SteerEnable = "1", APSteerRssiTh = "-54", DhcpCtl = "0",
		BhPriority2G = "3", BhPriority5GL = "1", BhPriority5GH = "1", BhPriority6G = "1",
		ChPlanningEnable = "1", NetworkOptimizationEnabled = "1", AutoBHSwitching = "1" }
	for key, value in pairs(defaults) do
		if c:get("mapd", "mapd_cfg", key) == nil then c:set("mapd", "mapd_cfg", key, value) end
	end
	if not c:get("1905d_cfg", "map", "map_ver") then c:set("1905d_cfg", "map", "map_ver", "R3") end
	if c:get("1905d_cfg", "map", "almac") == "02:00:00:00:00:01" then c:delete("1905d_cfg", "map", "almac") end
	c:commit("mapd")
	c:commit("1905d_cfg")
	return true
end

function M.interfaces()
	local c, result, radios, slots = uci.cursor(), {}, {}, {}
	local profile = l1.load_l1_profile(l1.L1_DAT_PATH)
	check(profile and profile.devname_ridx, "cannot load wireless L1 profile")
	c:foreach("wireless", "wifi-device", function(radio)
		if radio.type == "mtwifi" then radios[radio[".name"]] = radio end
	end)
	c:foreach("wireless", "wifi-iface", function(iface)
		local radio = radios[iface.device]
		local dev = profile.devname_ridx[iface.device]
		if not radio or not dev or (iface.mode ~= "ap" and iface.mode ~= "sta") then return end
		local key = iface.device .. ":" .. iface.mode
		local slot = slots[key] or 0
		slots[key] = slot + 1
		local name = iface.mode == "ap" and (dev.ext_ifname .. slot) or (dev.apcli_ifname .. slot)
		check(M.ifname(name) and M.ifname(dev.main_ifname), "invalid L1 interface name")
		local flags = tonumber(fs.readfile("/sys/class/net/" .. name .. "/flags") or "0") or 0
		result[#result + 1] = { ifname = name, main = dev.main_ifname, device = iface.device,
			section = iface[".name"], mode = iface.mode, band = (radio.band or ""):lower(),
			profile = dev.profile_path, map_mode = radio.map_mode or "0", network = iface.network,
			active = radio.disabled ~= "1" and iface.disabled ~= "1" and flags % 2 == 1 }
	end)
	return result
end

-- Add only the bSTA interfaces needed by an agent. Existing user interfaces
-- retain their network and credentials; managed empty bSTAs wait for onboarding.
function M.configure()
	local c, changed, radios, stations = uci.cursor(), false, {}, {}
	local enabled = c:get("mapd", "mapd_cfg", "enable") == "1"
	local role = c:get("mapd", "mapd_cfg", "DeviceRole") or "2"
	c:foreach("wireless", "wifi-device", function(radio)
		if radio.type == "mtwifi" then radios[#radios + 1] = radio end
	end)
	c:foreach("wireless", "wifi-iface", function(iface)
		if iface.mode == "sta" then stations[iface.device] = iface end
	end)
	for _, radio in ipairs(radios) do
		local name = radio[".name"]
		if radio.map_mode == nil and enabled then c:set("wireless", name, "map_mode", "1"); changed = true end
		local needed = enabled and role ~= "1" and radio.disabled ~= "1" and (radio.map_mode == nil or radio.map_mode == "1")
		local sta = stations[name]
		if needed and not sta then
			local section = "map_bsta_" .. name
			check(section:match("^[%w_]+$") and not c:get("wireless", section), "backhaul section name is already occupied")
			check(c:set("wireless", section, "wifi-iface"), "cannot create backhaul section")
			for key, value in pairs({ device = name, mode = "sta", network = c:get("mapd", "mapd_cfg", "network") or "lan",
				encryption = "none", ssid = "", multi_ap = "1", mapd_managed = "1", disabled = "0" })
			do check(c:set("wireless", section, key, value), "cannot configure backhaul interface") end
			changed = true
		elseif sta and sta.mapd_managed == "1" then
			local disabled = needed and "0" or "1"
			if sta.disabled ~= disabled then c:set("wireless", sta[".name"], "disabled", disabled); changed = true end
			local network = c:get("mapd", "mapd_cfg", "network") or "lan"
			if needed and sta.network ~= network then c:set("wireless", sta[".name"], "network", network); changed = true end
		end
	end
	if changed then check(c:commit("wireless"), "cannot save backhaul interfaces") end
	return changed
end

function M.save_backhaul(ifname)
	check(M.ifname(ifname), "invalid backhaul interface")
	local c, found = uci.cursor(), false
	if c:get("mapd", "mapd_cfg", "enable") ~= "1" then return true end
	for _, iface in ipairs(M.interfaces()) do
		if iface.ifname == ifname and iface.mode == "sta" and c:get("wireless", iface.section, "mapd_managed") == "1" then found = true end
	end
	if not found then return true end
	local ok, reply = M.exec({ "/usr/sbin/wpa_cli", "-p", "/var/run/wpa_supplicant", "-i", ifname, "save_config" })
	check(ok and reply:match("OK"), "cannot save backhaul credentials")
	local data = check(fs.readfile("/var/run/wpa_supplicant/wpa_supplicant-" .. ifname .. ".conf"), "missing backhaul configuration")
	check(data:match("network%s*={") and data:match("ssid="), "backhaul is not configured")
	M.atomic("/etc/map/backhaul-" .. ifname .. ".conf", data)
	return true
end

-- Preserve an agent's learned AP credentials when wapp enables/reconfigures a
-- BSS. Read only that BSS's configuration block, including keys containing '='.
function M.save_ap(ifname, from_wps)
	check(M.ifname(ifname), "invalid AP interface")
	local c, target = uci.cursor(), nil
	if c:get("mapd", "mapd_cfg", "enable") ~= "1" or not from_wps and c:get("mapd", "mapd_cfg", "DeviceRole") == "1" then return true end
	for _, iface in ipairs(M.interfaces()) do
		if iface.ifname == ifname and iface.mode == "ap" then target = iface.section end
	end
	if not target then return true end
	local config = fs.readfile("/var/run/hostapd/hostapd-" .. ifname .. ".conf")
	if not config then return true end
	local active, values = false, {}
	for line in config:gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key == "interface" or key == "bss" then active = value == ifname end
		if active and key then values[key] = value end
	end
	local ssid = values.ssid
	if values.ssid2 and values.ssid2:match("^%x+$") and #values.ssid2 % 2 == 0 then
		ssid = values.ssid2:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end)
	end
	if not ssid or #ssid == 0 or #ssid > 32 then return true end
	local auth, key = values.wpa_key_mgmt or "", values.wpa_passphrase or values.wpa_psk or values.sae_password
	local encryption
	if auth:find("SAE", 1, true) then encryption = auth:find("WPA-PSK", 1, true) and "sae-mixed" or "sae"
	elseif auth:find("WPA-PSK", 1, true) then encryption = "psk2"
	elseif auth:find("OWE", 1, true) then encryption = "owe"
	elseif values.wpa == "0" then encryption = "none" end
	if not encryption or (encryption ~= "none" and encryption ~= "owe" and not key) then return true end
	c:set("wireless", target, "ssid", M.scalar(ssid))
	c:set("wireless", target, "encryption", encryption)
	if values.multi_ap and values.multi_ap:match("^[0-3]$") then c:set("wireless", target, "multi_ap", values.multi_ap) end
	if key then c:set("wireless", target, "key", M.scalar(key)) else c:delete("wireless", target, "key") end
	check(c:commit("wireless"), "cannot save learned AP configuration")
	return true
end

function M.add_bss(ifname)
	check(M.ifname(ifname), "invalid AP interface")
	local profile = check(l1.load_l1_profile(l1.L1_DAT_PATH), "missing L1 profile")
	local dev = check(profile.ifname_ridx[ifname], "AP interface is not in the L1 profile")
	local index = tonumber(ifname:match("^" .. dev.ext_ifname:gsub("(%W)", "%%%1") .. "(%d+)$"))
	check(index and index >= 0 and index < 16, "invalid AP slot")
	local radio, base, target
	local c, count = uci.cursor(), 0
	check(c:get("mapd", "mapd_cfg", "enable") == "1", "EasyMesh is disabled")
	for _, iface in ipairs(M.interfaces()) do
		if iface.main == dev.main_ifname and iface.mode == "ap" then
			radio = iface.device
			count = count + 1
			if iface.active and not base then base = iface end
			if iface.ifname == ifname then target = iface.section end
		end
	end
	check(base and radio and base.map_mode == "1", "no local MAP radio configuration for new BSS")
	check(target or index == count, "new BSS slots must be allocated consecutively")
	local config = check(fs.readfile("/var/run/hostapd-" .. dev.main_ifname .. ".conf"), "missing radio hostapd configuration")
	local lines = {}
	for line in config:gmatch("[^\r\n]+") do
		if line:match("^bss=") then break end
		if line:match("^interface=") then line = "interface=" .. ifname end
		lines[#lines + 1] = line
	end
	local path = "/var/run/hostapd/hostapd-" .. ifname .. ".conf"
	if not target then
		check(not c:get("wireless", "map_ap_" .. ifname), "MAP BSS section already exists")
		M.atomic(path, table.concat(lines, "\n") .. "\n")
	end
	local phy = (fs.readfile("/sys/class/net/" .. dev.main_ifname .. "/phy80211/name") or ""):match("%S+")
	check(M.ifname(phy), "missing registered PHY")
	local ok, reply = M.exec({ "/usr/sbin/hostapd_cli", "-g", "/var/run/hostapd/global", "raw", "ADD", "bss_config=" .. phy .. ":" .. path })
	check(ok and reply:match("OK"), "hostapd could not add MAP BSS")
	if not target then
		local name = "map_ap_" .. ifname
		check(not c:get("wireless", name), "MAP BSS section already exists")
		section(c, "wireless", name, "wifi-iface", { device = radio, mode = "ap", network = c:get("mapd", "mapd_cfg", "network") or "lan",
			ssid = c:get("wireless", base.section, "ssid") or "", encryption = c:get("wireless", base.section, "encryption") or "none",
			key = c:get("wireless", base.section, "key") or "", multi_ap = "3", mapd_managed = "1" })
		check(c:commit("wireless"), "cannot save MAP BSS")
	end
	return true
end

local radio_ids = { ["2g"] = "8x", ["2.4g"] = "8x", ["5g"] = "11x", ["6g"] = "13x" }
local auth_modes = { psk2 = "0x0020", sae = "0x0040", ["sae-mixed"] = "0x0060", none = "0x0001", owe = "0x0080" }
local function token(value)
	return M.scalar(value):gsub("\\", "\\\\"):gsub("%s", "\\ ")
end

local function bss_line(index, bss, groups)
	local ssid, key = M.scalar(bss.ssid or ""), M.scalar(bss.PSK or "")
	check(#ssid > 0 and #ssid <= 32, "BSS SSID must contain 1 to 32 bytes")
	check(M.mac(bss.mac or ""), "invalid BSS radio MAC")
	check(({ ["8x"] = true, ["11x"] = true, ["12x"] = true, ["13x"] = true })[bss.radio], "invalid BSS radio band")
	check(bss.bhbss == "0" or bss.bhbss == "1", "invalid backhaul BSS flag")
	check(bss.fhbss == "0" or bss.fhbss == "1", "invalid fronthaul BSS flag")
	check(auth_modes.none == bss.authmode or auth_modes.owe == bss.authmode or #key >= 8 and #key <= 64, "BSS password must contain 8 to 64 bytes")
	check(bss.bhbss ~= "1" or bss.authmode ~= auth_modes.none, "wireless backhaul needs WPA2/WPA3 security")
	check(bss.authmode and bss.authmode:match("^0x%x%x%x%x$") and bss.EncryptType and bss.EncryptType:match("^0x%x%x%x%x$"), "invalid BSS security mode")
	local group = tonumber(bss.mld_groupID or "0")
	check(group and group % 1 == 0 and group >= 0 and group <= 48, "invalid MLD group ID")
	if group > 0 and group <= 16 then
		local signature = table.concat({ ssid, key, bss.authmode, bss.EncryptType }, "\000")
		check(not groups[group] or groups[group] == signature, "MLD group requires matching SSID and security")
		groups[group] = signature
	end
	local vid, pcp = tonumber(bss.vlan or "4095"), bss.pcp or "N/A"
	check(vid and vid % 1 == 0 and vid >= 1 and vid <= 4095, "invalid BSS VLAN")
	check(pcp == "N/A" or pcp:match("^[0-7]$"), "invalid BSS PCP")
	check(bss.pvid == nil or bss.pvid == "N/A" or bss.pvid == "pvid", "invalid BSS PVID")
	-- The vendor parser expects a delimiter after the group ID.
	return string.format("%d,%s %s %s %s %s %s %s %s hidden-%s %d %s %s mld_groupID %d \n",
		index, bss.mac, bss.radio, token(ssid), bss.authmode, bss.EncryptType, token(key ~= "" and key or "NULL"),
		bss.bhbss, bss.fhbss, bss.hidden == "Y" and "Y" or "N", vid, bss.pvid or "N/A", pcp, group)
end

function M.prepare()
	local c = uci.cursor()
	check(c:get("mapd", "mapd_cfg", "enable") == "1", "EasyMesh is disabled")
	local cfg = c:get_all("mapd", "mapd_cfg") or {}
	local role, version = cfg.DeviceRole or "2", c:get("1905d_cfg", "map", "map_ver") or "R3"
	check(role == "0" or role == "1" or role == "2", "invalid device role")
	check(version == "R1" or version == "R2" or version == "R3", "this build supports MAP R1/R2/R3")
	local network = cfg.network or "lan"
	check(network:match("^[%w_]+$"), "invalid LAN network")
	local ok, status = M.exec({ "/bin/ubus", "call", "network.interface." .. network, "status" })
	local decoded, data = pcall(json.decode, status)
	check(ok and decoded and type(data) == "table" and data.up, "LAN network is not ready")
	local bridge = data.l3_device or data.device
	check(M.ifname(bridge) and fs.access("/sys/class/net/" .. bridge .. "/bridge"), "EasyMesh LAN must use an existing bridge")
	local ports = {}
	for port in fs.dir("/sys/class/net/" .. bridge .. "/brif") do
		if M.ifname(port) and not fs.access("/sys/class/net/" .. port .. "/phy80211") and
			not fs.access("/sys/class/net/" .. port .. "/wireless") then ports[#ports + 1] = port end
	end
	table.sort(ports)
	local almac = c:get("1905d_cfg", "map", "almac") or (fs.readfile("/sys/class/net/" .. bridge .. "/address") or ""):match("%S+")
	check(M.mac(almac) and tonumber(almac:sub(1, 2), 16) % 2 == 0 and almac ~= "00:00:00:00:00:00", "invalid AL MAC")
	local interfaces, aps, mains, seen, bands = M.interfaces(), {}, {}, {}, {}
	for _, iface in ipairs(interfaces) do
		if iface.active and iface.map_mode == "1" then
			local networks = type(iface.network) == "table" and iface.network or {}
			if type(iface.network) == "string" then
				for name in iface.network:gmatch("%S+") do networks[#networks + 1] = name end
			end
			check(#networks == 1 and networks[1] == network,
				"MAP interface " .. iface.ifname .. " must belong only to " .. network .. "; traffic separation is not configured")
			check(flat(iface.profile).MapMode == "1", "radio MAP mode changed; apply wireless configuration first")
			if iface.mode == "ap" then
				aps[#aps + 1] = iface
				if not seen[iface.main] then
					mains[#mains + 1] = iface.main
					bands[#bands + 1] = check(({ ["2g"] = "24G", ["2.4g"] = "24G", ["5g"] = "5GL", ["6g"] = "6G" })[iface.band], "unknown radio band")
					seen[iface.main] = true
				end
			end
		end
	end
	check(#aps > 0, "no active MAP AP interface; apply wireless configuration first")
	local values = merge(flat("/etc/map/mapd_default.cfg"), flat("/etc/map/mapd_user.cfg"))
	merge(values, c:get_all("mapd", "mapd_user"))
	merge(values, cfg)
	values.enable, values.Enable, values.network = nil, nil, nil
	-- netifd owns addressing and DHCP, including after controller changes.
	values.DhcpCtl = "0"
	values.DeviceRole, values.lan_interface = role, table.concat(ports, " ")
	values.wan_interface = c:get("network", "wan", "device") or ""
	values.bss_config_priority = table.concat(mains, ";")
	local strng = merge(flat("/etc/mapd_strng.conf"), c:get_all("mapd", "mapd_strng"))
	for _, key in ipairs({ "CUOverloadTh_2G", "CUOverloadTh_5G_L", "CUOverloadTh_5G_H", "CUOverloadTh_6G" }) do
		if cfg[key] then strng[key] = cfg[key] end
	end
	local dpp = merge(flat("/etc/dpp_cfg.txt"), c:get_all("mapd", "dpp_cfg"))
	dpp.allowed_role, dpp.map_support = ({ ["0"] = "0", ["1"] = "2", ["2"] = "1" })[role], "1"
	dpp.curve_name = dpp.curve_name or "prime256v1"
	if not ({ ["2g"] = true, ["5g"] = true, ["6g"] = true })[dpp.presence_band_priority] then dpp.presence_band_priority = "5g" end
	local p1905 = flat("/etc/map/1905d.cfg")
	p1905.map_controller_alid, p1905.map_agent_alid, p1905.br_inf = almac, almac, bridge
	p1905.map_agent, p1905.map_root = role == "1" and "0" or "1", role == "1" and "1" or "0"
	p1905.map_ver, p1905.radio_band = version, table.concat(bands, ";") .. ";"
	p1905.bss_config_priority, p1905.lan, p1905.wan = values.bss_config_priority, nil, nil
	local p1905_text = flat_text(p1905)
	for _, port in ipairs(ports) do p1905_text = p1905_text .. "lan=" .. port .. "\n" end
	local bss, groups = { "#ucc_bss_info\n" }, {}
	c:foreach("mapd", "iface", function(iface) bss[#bss + 1] = bss_line(#bss, iface, groups) end)
	if #bss == 1 then
		for _, iface in ipairs(aps) do
			local w = c:get_all("wireless", iface.section) or {}
			local encryption = (w.encryption or "none"):match("^[^+]+")
			local multi_ap = tonumber(w.multi_ap or "0") or 0
			local secure = encryption == "psk2" or encryption == "sae" or encryption == "sae-mixed"
			if multi_ap == 0 then multi_ap = secure and 3 or 2 end
			bss[#bss + 1] = bss_line(#bss, { mac = "ff:ff:ff:ff:ff:ff", radio = radio_ids[iface.band],
				ssid = w.ssid, PSK = w.key, authmode = check(auth_modes[encryption], "unsupported MAP BSS encryption"),
				EncryptType = encryption == "none" and "0x0001" or "0x0008", bhbss = multi_ap % 2 == 1 and "1" or "0",
				fhbss = multi_ap >= 2 and "1" or "0", hidden = w.hidden == "1" and "Y" or "N",
				mld_groupID = w.mldgroup or (w.mlo == "1" and "1" or "0") }, groups)
		end
	end
	local bhsta = { "#ucc_bhsta_info\n" }
	c:foreach("mapd", "bh_sta", function(sta)
		local links = tonumber(sta.mlo_links)
		check(M.mac(sta.almac) and links and links >= 1 and links <= 3 and links % 1 == 0, "invalid backhaul MLD")
		local ids = type(sta.ruid_or_band) == "table" and sta.ruid_or_band or {}
		if #ids == 0 then for id in tostring(sta.ruid_or_band or ""):gmatch("%S+") do ids[#ids + 1] = id end end
		check(#ids == links, "backhaul MLD link count does not match radio list")
		for _, id in ipairs(ids) do check(id:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") or id:match("^1[123]x$") or id == "8x", "invalid backhaul radio") end
		bhsta[#bhsta + 1] = string.format("%d,%s %d %s\n", #bhsta, sta.almac, links, table.concat(ids, " "))
	end)
	fs.mkdirr("/var/run/easymesh")
	local confs = {}
	for _, main in ipairs(mains) do
		local source = fs.readfile("/etc/wapp_ap_" .. main .. ".conf") or fs.readfile("/etc/wapp_ap_" .. main .. "_default.conf") or fs.readfile("/etc/wapp_ap_ra0_default.conf")
		check(source, "missing wapp AP configuration template")
		source = source:gsub("interface=[^\r\n]+", "interface=" .. main)
		local path = "/var/run/easymesh/wapp_" .. main .. ".conf"
		M.atomic(path, source)
		confs[#confs + 1] = path
	end
	M.atomic("/etc/map/mapd_cfg", flat_text(values))
	M.atomic("/etc/mapd_strng.conf", flat_text(strng))
	M.atomic("/etc/dpp_cfg.txt", flat_text(dpp))
	M.atomic("/etc/map/1905d.cfg", p1905_text)
	local eth = flat("/etc/ethernet_cfg.txt")
	eth.br_lan, eth.lan = bridge, table.concat(ports, " ")
	M.atomic("/etc/ethernet_cfg.txt", flat_text(eth))
	M.atomic("/etc/map/wts_bss_info_config", table.concat(bss))
	M.atomic("/etc/map/wts_bsta_mlo_config", table.concat(bhsta))
	M.atomic("/var/run/easymesh/wapp.conf", "conf_list=" .. table.concat(confs, ";") .. ";\n")
	M.atomic("/etc/wapp_main_inf.conf", "all_main_inf=" .. table.concat(mains, ";") .. ";\n")
	local state = { role = role, almac = almac, bridge = bridge, interfaces = interfaces, mains = mains }
	M.atomic(M.state_path, json.encode(state))
	return true
end

function M.run_daemon(daemon)
	local state = check(M.read_json(M.state_path), "missing prepared runtime state")
	local commands = {
		wapp = { "/usr/bin/wapp", "-d1", "-v2", "-iNL80211", "-f/var/run/easymesh/wapp.conf" },
		p1905 = { "/usr/bin/p1905_managerd", state.role == "1" and "-r0" or "-r1", "-f", "/etc/map/1905d.cfg", "-F", "/etc/map/wts_bss_info_config" },
		mapd = { "/usr/bin/mapd", "-I", "/etc/map/mapd_cfg", "-O", "/etc/mapd_strng.conf" }
	}
	local command = check(commands[daemon], "unknown daemon")
	if daemon == "wapp" then
		check(M.exec({ "/sbin/modprobe", "mapfilter" }), "cannot load mapfilter")
		for _, iface in ipairs(state.interfaces) do
			if iface.active and iface.map_mode == "1" and iface.mode == "ap" then command[#command + 1] = "-c" .. iface.ifname end
		end
	else
		for _, path in ipairs(daemon == "mapd" and { "/tmp/wapp_ctrl", "/tmp/1905ctrl" } or { "/tmp/wapp_ctrl" }) do
			local ready = false
			for _ = 1, 50 do
				if fs.stat(path, "type") == "sock" then ready = true; break end
				nixio.nanosleep(0, 200000000)
			end
			check(ready, "dependency socket is not ready: " .. path)
		end
	end
	local executable = table.remove(command, 1)
	nixio.exec(executable, unpack(command))
	error("cannot execute " .. executable)
end

return M

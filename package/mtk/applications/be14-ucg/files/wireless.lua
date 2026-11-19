#!/usr/bin/lua
-- Local interface between the inform client and the WEXT manager.
local json, uci, ubus = require("cjson"), require("uci"), require("ubus")
local l1, defs = require("l1dat_parser"), require("mtwifi_defs")
local fs = require("nixio.fs")
local fields = {"ssid", "encryption", "key", "ieee80211w", "hidden", "isolate"}
local bus = assert(ubus.connect())
local req = json.decode(io.read("*a"))
local cursor = uci.cursor(nil, arg[1])
local config = assert(cursor:get_all("be14_ucg", "main"))
assert(config.enabled == "1", "agent disabled")

local function call(obj, method, data)
    return bus:call(obj, method, data or {}) or {}
end

local function selected()
    local selected = {}
    local names = config.section or {}
    if type(names) == "string" then names = {names} end
    for _, name in ipairs(names) do
        assert(name:match("^be14_ucg_[%w_]+$") and not selected[name], "invalid local AP binding")
        selected[name] = true
    end
    return selected
end

local codes = { ["2g"] = "ng", ["5g"] = "na", ["6g"] = "6e" }
local radio_names = { ng = "wifi0", na = "wifi1", ["6e"] = "wifi2" }

local function dbm(value)
    if type(value) ~= "number" then return end
    -- rpcd serializes dBm in a 32-bit ubus integer.
    if value >= 2^31 then value = value - 2^32 end
    if value < 0 and value >= -127 then return value end
end

local function station_table(stations, hosts, ap)
    local rows, seen = {}, {}
    for _, sta in ipairs(stations) do
        local mac = type(sta.mac) == "string" and sta.mac:lower() or ""
        if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") and mac ~= "00:00:00:00:00:00"
            and tonumber(mac:sub(1, 2), 16) % 2 == 0 and not seen[mac] then
            seen[mac] = true
            local host = hosts[mac] or hosts[mac:upper()] or {}
            local row = {mac=mac, vap_name=ap.name, radio=ap.radio, channel=ap.channel,
                uptime=sta.connected_time, signal=dbm(sta.signal), noise=dbm(sta.noise),
                ip=(host.ipaddrs or {})[1], hostname=host.name}
            if row.signal and row.noise then row.rssi = row.signal - row.noise end
            for _, dir in ipairs({"rx", "tx"}) do
                local stats = sta[dir] or {}
                for _, key in ipairs({"rate", "bytes", "packets"}) do
                    row[dir .. "_" .. key] = stats[key]
                end
            end
            rows[#rows+1] = row
        end
    end
    return rows
end

local function snapshot()
    local profile = assert(l1.load_l1_profile(l1.L1_DAT_PATH))
    local status = call("network.wireless", "status")
    local radios, aps, bindings = {}, {}, {}
    local hosts
    local owned = selected()
    for name, dev in pairs(profile.devname_ridx) do
        local band = l1.device_band(dev)
        local code = codes[band]
        if dev.INDEX == "MT7990" and code then
            assert(not radios[code], "ambiguous BE14 radio")
            local radio = status[name] or {}
            local row = { name = radio_names[code], radio = code, up = radio.up == true,
                ifname = dev.main_ifname, applied_htmode = (radio.config or {}).htmode }
            radios[code] = row
            local main = radio.up and call("iwinfo", "info", {device=dev.main_ifname}) or {}
            row.channel, row.tx_power = main.channel, main.txpower
            row.live_htmode = main.htmode
            local live = {}
            for _, v in ipairs(radio.interfaces or {}) do
                if radio.up and v.ifname and v.ifname:match("^" .. dev.ext_ifname .. "%d+$") then
                    live[v.section] = v
                end
            end
            cursor:foreach("wireless", "wifi-iface", function(c)
                if c.device ~= name or c.mode ~= "ap" then return end
                local section = c[".name"]
                local vif = live[section]
                local iface = vif and vif.ifname
                local info = iface and call("iwinfo", "info", {device=iface}) or {}
                local observed = iface and info.ssid and info.ssid ~= "" and info.ssid or nil
                row.channel = row.channel or info.channel
                row.tx_power = row.tx_power or info.txpower
                row.live_htmode = row.live_htmode or info.htmode
                if owned[section] then
                    assert(c.mldgroup == "0" and not defs.disabled(c.mlo) and not defs.disabled(c.disabled),
                        "bind an enabled independent test AP with mldgroup 0")
                    assert(not bindings[code], "multiple AP bindings on one band")
                    local applied = {}
                    for _, k in ipairs(fields) do
                        local value = vif and vif.config and vif.config[k]
                        if value ~= nil then
                            applied[k] = value == true and "1" or value == false and "0" or tostring(value)
                        end
                    end
                    bindings[code] = {section=section, ssid=c.ssid, observed=observed, applied=applied,
                        encryption=c.encryption, ieee80211w=c.ieee80211w, key=c.key, isolate=c.isolate,
                        hidden=c.hidden, device=name}
                    owned[section] = nil
                end
                if observed and info.bssid then
                    local ap = {section=section, name=iface, radio=code, radio_name=row.name,
                        essid=observed, bssid=info.bssid:lower(), channel=info.channel,
                        tx_power=info.txpower or row.tx_power, up=true}
                    local stations = call("iwinfo", "assoclist", {device=iface}).results
                    if type(stations) == "table" then
                        if #stations > 0 and not hosts then hosts = call("luci", "getHostHints") end
                        ap.sta_table = station_table(stations, hosts or {}, ap)
                    end
                    aps[#aps+1] = ap
                elseif iface then
                    row.incomplete_associations = true
                end
            end)
        end
    end
    assert(radios.ng and radios.na and radios["6e"], "BE14 tri-band L1 profile required")
    assert(not next(owned), "bound test AP missing")
    local net = assert(config.management_network)
    assert(net:match("^[%w_]+$"), "invalid management network")
    local iface = call("network.interface." .. net, "status")
    local dev = iface.l3_device or iface.device
    assert(dev and dev:match("^[%w_.-]+$"), "management interface unavailable")
    local addr = (iface["ipv4-address"] or {})[1]
    local mac = fs.readfile("/sys/class/net/" .. dev .. "/address")
    return {radios=radios, aps=aps, bindings=bindings, mac=mac and mac:match("%S+"),
        ip=addr and addr.address, url=config.inform_url, wlan_id=config.wlan_id or "",
        sshd_port=tonumber(config.sshd_port or 22)}
end

if req.op == "snapshot" then
    print(json.encode(snapshot()))
elseif req.op == "settings" then
    print(json.encode({url=config.inform_url}))
elseif req.op == "replace" then
    -- Compare all fields we own and validate all bindings before staging one UCI commit.
    local normal = uci.cursor()
    assert(not next(normal:changes("wireless") or {}), "pending local wireless edits")
    local state = snapshot()
    local allowed = {}
    for _, k in ipairs(fields) do allowed[k] = true end
    for code, change in pairs(req.changes) do
        local current = assert(state.bindings[code])
        assert(current.section == change.section and current.device == change.device, "AP binding changed")
        for k in pairs(allowed) do
            local now = cursor:get("wireless", current.section, k)
            assert((now or false) == (change.before[k] or false), "AP changed locally")
        end
        for k in pairs(change.after) do assert(allowed[k], "unsupported AP setting") end
    end
    for _, c in pairs(req.changes) do
        for k in pairs(allowed) do
            if c.after[k] then
                assert(cursor:set("wireless", c.section, k, c.after[k]))
            elseif c.before[k] then
                assert(cursor:delete("wireless", c.section, k))
            end
        end
    end
    assert(cursor:commit("wireless"), "wireless commit failed")
    print("{}")
else
    error("unknown local operation")
end

local M = {}

local wireless_modes = {
    ["2g"] = { NOHT = 0, HT = 9, HE = 16, EHT = 22 },
    ["5g"] = { NOHT = 2, HT = 8, VHT = 14, HE = 17, EHT = 23 },
    ["6g"] = { HE = 18, EHT = 24 }
}

local function center80(band, channel)
    if type(channel) == "string" and not channel:match("^%d+$") then return nil end
    channel = tonumber(channel)
    if not channel then return nil end
    if band == "6g" and channel >= 1 and channel <= 221 and channel % 4 == 1 then
        return 7 + 16 * math.floor((channel - 1) / 16)
    elseif band == "5g" then
        for _, center in ipairs({42, 58, 106, 122, 138, 155, 171}) do
            if channel >= center - 6 and channel <= center + 6 and (channel - center + 6) % 4 == 0 then
                return center
            end
        end
    end
end

function M.apply(config, dats)
    local htmode = config.htmode
    local family, width, suffix
    if htmode == "NOHT" then
        family, width, suffix = "NOHT", 20, ""
    elseif type(htmode) == "string" then
        family, width, suffix = htmode:match("^(%u+)(%d+)(.*)$")
        width = tonumber(width)
    end
    local split = suffix == "_80" and width == 80 and (family == "VHT" or family == "HE")
    local modes = wireless_modes[config.band]
    local wmode = modes and modes[family] or nil
    if wmode == nil or not width or
        (width ~= 20 and width ~= 40 and width ~= 80 and width ~= 160 and width ~= 320) or
        (suffix ~= "" and not split and not (width == 40 and (suffix == "+" or suffix == "-"))) or
        (family == "HT" and width > 40) or
        (config.band == "2g" and width > 40) or
        (width == 320 and (config.band ~= "6g" or family ~= "EHT")) then
        return nil, "invalid mode or bandwidth for this band"
    end
    if split then
        local first, second = center80(config.band, config.channel), center80(config.band, config.channel2)
        if not first or not second or math.abs(first - second) <= 16 then
            return nil, "80+80 MHz requires two fixed, non-adjacent 80 MHz channel segments"
        end
    end
    if family == "NOHT" and config.band == "2g" and config.hwmode == "11b" then
        wmode = 1
    end

    dats.HT_BW, dats.VHT_BW, dats.EHT_ApBw = 0, 0, 0
    if width >= 40 then
        dats.HT_BW = 1
        dats.VHT_BW = width >= 160 and 2 or width == 80 and 1 or 0
        if family == "EHT" then
            dats.EHT_ApBw = ({ [40] = 1, [80] = 2, [160] = 3, [320] = 4 })[width]
        end
    end
    if width == 40 then
        local noscan = config.noscan
        dats.HT_BSSCoexistence = (noscan == true or noscan == 1 or noscan == "1") and 0 or 1
    end
    if suffix == "+" then
        dats.HT_EXTCHA = 1
    elseif suffix == "-" or width == 320 then
        dats.HT_EXTCHA = 0
    end
    local secondary = {}
    for i = 1, tonumber(dats.BssidNum) or 1 do
        secondary[i] = split and tostring(config.channel2) or "0"
    end
    dats.VHT_Sec80_Channel = table.concat(secondary, ";")
    if split then dats.VHT_BW = 3 end

    return true, nil, wmode
end

return M

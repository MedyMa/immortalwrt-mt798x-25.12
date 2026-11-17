local M = {}

local wireless_modes = {
    ["2g"] = { NOHT = 0, HT = 9, HE = 16, EHT = 22 },
    ["5g"] = { NOHT = 2, HT = 8, VHT = 14, HE = 17, EHT = 23 },
    ["6g"] = { HE = 18, EHT = 24 }
}

function M.apply(config, dats)
    local htmode = config.htmode
    local family, width, suffix
    if htmode == "NOHT" then
        family, width, suffix = "NOHT", 20, ""
    elseif type(htmode) == "string" then
        family, width, suffix = htmode:match("^(%u+)(%d+)(.*)$")
        width = tonumber(width)
    end
    local modes = wireless_modes[config.band]
    local wmode = modes and modes[family] or nil
    if wmode == nil or not width or
        (width ~= 20 and width ~= 40 and width ~= 80 and width ~= 160 and width ~= 320) or
        (suffix ~= "" and not (width == 40 and (suffix == "+" or suffix == "-"))) or
        (family == "HT" and width > 40) or
        (config.band == "2g" and width > 40) or
        (width == 320 and (config.band ~= "6g" or family ~= "EHT")) then
        return nil, "invalid mode or bandwidth for this band"
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

    return true, nil, wmode
end

return M

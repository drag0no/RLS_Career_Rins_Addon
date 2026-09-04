local M = {}

local lastSentTime = nil
local lastSentMinute = nil

local function formatTime(t)
    -- BeamNG TimeOfDay uses 0=noon and 0.5=midnight. Convert to a normal
    -- midnight-based clock before formatting it for the phone.
    local total_minutes = ((t + 0.5) % 1) * 1440
    local hours = math.floor(total_minutes / 60)
    local minutes = math.floor(total_minutes % 60)
    local period = hours < 12 and "AM" or "PM"
    local twelve_hour = hours % 12
    twelve_hour = twelve_hour == 0 and 12 or twelve_hour
    return string.format("%d:%02d %s", twelve_hour, minutes, period)
end

local function getTime()
    if scenetree and scenetree.tod and scenetree.tod.time ~= nil then
        return formatTime(scenetree.tod.time)
    end
    return nil
end

local function requestTime()
    local tod = scenetree and scenetree.tod and scenetree.tod.time
    local formatted = tod ~= nil and formatTime(tod) or nil
    if formatted then
        lastSentMinute = math.floor(tod * 1440)
        lastSentTime = formatted
        guihooks.trigger("phone_time_update", formatted)
    end
end

local function onUpdate()
    local tod = scenetree and scenetree.tod and scenetree.tod.time
    if tod == nil then return end
    local minute = math.floor(tod * 1440)
    if minute == lastSentMinute then return end

    local formatted = formatTime(tod)
    lastSentMinute = minute
    if formatted and formatted ~= lastSentTime then
        lastSentTime = formatted
        guihooks.trigger("phone_time_update", formatted)
    end
end

local function onExtensionLoaded()
    local tod = scenetree and scenetree.tod and scenetree.tod.time
    local formatted = tod ~= nil and formatTime(tod) or nil
    if formatted then
        lastSentMinute = math.floor(tod * 1440)
        lastSentTime = formatted
        guihooks.trigger("phone_time_update", formatted)
    end
end

local function clearTime()
    lastSentTime = nil
    lastSentMinute = nil
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.clearTime = clearTime
M.requestTime = requestTime

return M

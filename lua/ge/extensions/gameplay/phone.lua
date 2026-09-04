local M = {}

local speedUnit = 2.2369362921

local isPhoneOpen = false
local updateTimer = 0
local updateInterval = 2.5

local function getCurrentRouteName()
    if type(extensions) ~= "table" or type(extensions.ui_router) ~= "table"
        or type(extensions.ui_router.getCurrent) ~= "function" then
        return nil
    end
    local current = extensions.ui_router.getCurrent()
    if not current then
        return nil
    end
    -- Prefer resolved name; fall back to the request that got us here.
    if current.resolved and type(current.resolved.name) == "string" then
        return current.resolved.name
    end
    if current.request and type(current.request.name) == "string" then
        return current.request.name
    end
    if current.toRoute and type(current.toRoute.name) == "string" then
        return current.toRoute.name
    end
    return nil
end

local function isComputerRouteName(name)
    if type(name) ~= "string" then
        return false
    end
    if name == "career.computer" or name:find("^career%.computer%.", 1) then
        return true
    end
    if name == "business-computer" then
        return true
    end
    return false
end

-- Facility / business computer menus own the main route; opening the phone
-- would unmount them and wipe in-progress work (parts cart, etc.).
local function isComputerMenuOpen()
    if isComputerRouteName(getCurrentRouteName()) then
        return true
    end
    -- Session flag covers cases where the router entry is briefly unavailable.
    if career_modules_partShopping and career_modules_partShopping.isShoppingSessionActive
        and career_modules_partShopping.isShoppingSessionActive() then
        return true
    end
    return false
end

local function notifyCloseComputerToOpenPhone()
    -- Computer routes hide UI apps (including the Messages app that renders
    -- ui_message), so use toastr which still shows over the computer UI.
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "Phone",
        msg = "Close the computer to open the phone.",
    })
end

local function blockPhoneIfComputerOpen()
    if not isComputerMenuOpen() then
        return false
    end
    notifyCloseComputerToOpenPhone()
    return true
end

local function togglePhone(reason)
    --ui_phone_time.clearTime()
    if isPhoneOpen then
        isPhoneOpen = false
        guihooks.trigger('closePhone')
    else
        if blockPhoneIfComputerOpen() then
            return
        end
        local playerSpeed = math.abs(be:getObjectVelocityXYZ(be:getPlayerVehicleID(0))) * speedUnit
        local inTaxiRide = gameplay_taxi and gameplay_taxi.isTaxiRideActive and gameplay_taxi.isTaxiRideActive()
        if (not inTaxiRide) and playerSpeed > 5 then
            if reason then
                ui_message(reason, 5, "info", "info")
            else
                ui_message("You must be stationary to open the phone.", 3, "info", "info")
            end
            return
        end
        isPhoneOpen = true
        if gameplay_rlsTaxi and gameplay_rlsTaxi.isTaxiJobActive and gameplay_rlsTaxi.isTaxiJobActive() then
            extensions.ui_router.navigate('phone-taxi')
        else
            extensions.ui_router.navigate('phone-main')
        end
    end
end

local function onExtensionLoaded()
    isPhoneOpen = false
    print("Phone extension loaded")
end

local function onUpdate(dt)
    updateTimer = updateTimer + dt
    if updateTimer > updateInterval then
        updateTimer = 0
        if isPhoneOpen then
            local playerSpeed = math.abs(be:getObjectVelocityXYZ(be:getPlayerVehicleID(0))) * speedUnit
            local inTaxiRide = gameplay_taxi and gameplay_taxi.isTaxiRideActive and gameplay_taxi.isTaxiRideActive()
            if (not inTaxiRide) and playerSpeed > 5 then
                isPhoneOpen = false
                ui_message("Phone closed due to player movement.", 3, "info", "info")
                guihooks.trigger('closePhone')
            end
        end
    end
end

M.onUIPlayStateChanged = function(changed)
    if changed then
        isPhoneOpen = false
    end
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
local function closePhone()
    if not isPhoneOpen then
        return
    end
    isPhoneOpen = false
    guihooks.trigger('closePhone')
end

-- Clears open state without UI close / closeAllMenus (e.g. leave phone via menu navigation).
local function markClosed()
    isPhoneOpen = false
end

local function markOpen()
    isPhoneOpen = true
end

-- Opens a specific phone route through BeamNG 0.39's authoritative Lua router.
-- Notification clicks use this instead of changing Vue history directly so the
-- gameplay-side open state, speed-close guard, and route lifecycle stay in sync.
local function openRoute(routeName, params)
    if type(routeName) ~= "string" or routeName == "" then
        return {success = false, reason = "invalid_route"}
    end

    if blockPhoneIfComputerOpen() then
        return {success = false, reason = "computer_open"}
    end

    isPhoneOpen = true
    local result = extensions.ui_router.navigate(routeName, params or {})
    if result and result.success == false then
        isPhoneOpen = false
    end
    return result
end

local function openForTutorial()
    if blockPhoneIfComputerOpen() then
        return
    end
    isPhoneOpen = true
    if gameplay_rlsTaxi and gameplay_rlsTaxi.isTaxiJobActive and gameplay_rlsTaxi.isTaxiJobActive() then
        extensions.ui_router.navigate('phone-taxi')
    else
        extensions.ui_router.navigate('phone-main')
    end
end

M.togglePhone = togglePhone
M.closePhone = closePhone
M.markClosed = markClosed
M.markOpen = markOpen
M.openRoute = openRoute
M.openForTutorial = openForTutorial
M.isPhoneOpen = function()
    return isPhoneOpen
end
M.isComputerMenuOpen = isComputerMenuOpen

return M

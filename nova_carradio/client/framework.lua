NovaCarRadioFramework = NovaCarRadioFramework or {}

local Config = NovaCarRadioConfig or {}
local activeFramework = nil
local core = nil
local lastAnnounced = nil

local aliases = {
    ['auto'] = 'auto',
    ['nova'] = 'nova',
    ['nova_core'] = 'nova',
    ['qb'] = 'qbcore',
    ['qbcore'] = 'qbcore',
    ['qb-core'] = 'qbcore',
    ['esx'] = 'esx',
    ['es_extended'] = 'esx',
    ['standalone'] = 'standalone',
    ['none'] = 'standalone',
}

local frameworkResources = { nova = 'nova_core', qbcore = 'qb-core', esx = 'es_extended' }

local function started(name)
    return name and GetResourceState(name) == 'started'
end

local function requestedFramework()
    local value = tostring(Config.Framework or 'auto'):lower():gsub('%s+', '')
    return aliases[value] or 'auto'
end

local function fetchCore(framework)
    if framework == 'nova' then
        local ok, value = pcall(function() return exports['nova_core']:GetCoreObject() end)
        return ok and type(value) == 'table' and value or nil
    elseif framework == 'qbcore' then
        local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
        return ok and type(value) == 'table' and value or nil
    elseif framework == 'esx' then
        local ok, value = pcall(function() return exports['es_extended']:getSharedObject() end)
        return ok and type(value) == 'table' and value or nil
    end
    return nil
end

function NovaCarRadioFramework.refresh(force)
    local requested = requestedFramework()
    local detected = requested
    if requested == 'auto' then
        if started('nova_core') then detected = 'nova'
        elseif started('qb-core') then detected = 'qbcore'
        elseif started('es_extended') then detected = 'esx'
        else detected = 'standalone' end
    end

    if force or detected ~= activeFramework then
        activeFramework = detected
        core = fetchCore(detected)
    elseif not core and detected ~= 'standalone' then
        core = fetchCore(detected)
    end

    if lastAnnounced ~= activeFramework then
        lastAnnounced = activeFramework
        print(('[NOVA CARRADIO] Framework: %s'):format(activeFramework))
    end
    return activeFramework
end

function NovaCarRadioFramework.getName()
    return NovaCarRadioFramework.refresh(false)
end

function NovaCarRadioFramework.isFrameworkResource(name)
    for _, resource in pairs(frameworkResources) do
        if name == resource then return true end
    end
    return false
end

local function fallbackNotify(text)
    SetNotificationTextEntry('STRING')
    AddTextComponentSubstringPlayerName(text)
    DrawNotification(false, false)
end

function NovaCarRadioFramework.notify(text, kind, duration)
    text = tostring(text or 'Car radio error.')
    kind = tostring(kind or 'error')
    duration = tonumber(duration) or 3500
    local framework = NovaCarRadioFramework.refresh(false)

    if framework == 'nova' and core and core.Functions and type(core.Functions.Notify) == 'function' then
        local ok = pcall(core.Functions.Notify, text, kind, duration)
        if ok then return true end
    elseif framework == 'qbcore' and core and core.Functions and type(core.Functions.Notify) == 'function' then
        local qbType = kind == 'info' and 'primary' or kind
        local ok = pcall(core.Functions.Notify, text, qbType, duration)
        if ok then return true end
    elseif framework == 'esx' and core and type(core.ShowNotification) == 'function' then
        local esxType = kind == 'primary' and 'info' or kind
        local ok = pcall(core.ShowNotification, text, esxType, duration)
        if ok then return true end
    end

    fallbackNotify(text)
    return false
end

AddEventHandler('onClientResourceStart', function(name)
    if not NovaCarRadioFramework.isFrameworkResource(name) then return end
    CreateThread(function()
        Wait(250)
        NovaCarRadioFramework.refresh(true)
    end)
end)

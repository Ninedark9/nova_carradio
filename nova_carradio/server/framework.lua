NovaCarRadioFramework = NovaCarRadioFramework or {}

local Config = NovaCarRadioConfig or {}
local activeFramework = nil
local core = nil
local lastAnnounced = nil
local callbacks = {}

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

local function normalizeId(value)
    if value == nil then return nil end
    value = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' or #value > 128 then return nil end
    return value
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

local function novaCharacterId(src)
    if not core or type(core.Functions) ~= 'table' then return nil end
    local F = core.Functions
    local id = NovaCarRadioCharacter and NovaCarRadioCharacter.resolve(src, {
        exportCharacterId = function()
            if not started('nova_core') then return nil end
            return exports['nova_core']:GetCharacterId(src)
        end,
        functionCharacterId = function()
            return type(F.GetCharacterId) == 'function' and F.GetCharacterId(src) or nil
        end,
        playerDataCharacterId = function()
            local data = type(F.GetPlayerData) == 'function' and F.GetPlayerData(src) or nil
            return data and (data.characterId or data.id) or nil
        end,
        playerObjectCharacterId = function()
            local player = type(F.GetPlayer) == 'function' and F.GetPlayer(src) or nil
            local data = player and player.PlayerData or nil
            return data and (data.characterId or data.id) or nil
        end,
        stateCharacterId = function()
            local ok, state = pcall(function() return Player(src).state end)
            return ok and state and state['nova:characterId'] or nil
        end,
    })
    return normalizeId(id)
end

local function qbPlayer(src)
    if not started('qb-core') then return nil end
    local ok, player = pcall(function() return exports['qb-core']:GetPlayer(src) end)
    if ok and player then return player end
    if core and core.Functions and type(core.Functions.GetPlayer) == 'function' then
        local okCore, corePlayer = pcall(core.Functions.GetPlayer, src)
        if okCore then return corePlayer end
    end
    return nil
end

local function esxPlayer(src)
    if not core then return nil end
    if type(core.GetPlayerFromId) == 'function' then
        local ok, player = pcall(core.GetPlayerFromId, src)
        if ok then return player end
    end
    if type(core.Player) == 'function' then
        local ok, player = pcall(core.Player, src)
        if ok then return player end
    end
    return nil
end

function NovaCarRadioFramework.getCharacterId(src)
    local framework = NovaCarRadioFramework.refresh(false)
    if framework == 'nova' then
        return novaCharacterId(src)
    elseif framework == 'qbcore' then
        local player = qbPlayer(src)
        local data = player and player.PlayerData or nil
        return normalizeId(data and data.citizenid)
    elseif framework == 'esx' then
        local player = esxPlayer(src)
        if not player then return nil end
        local value = nil
        if type(player.getIdentifier) == 'function' then
            local ok, result = pcall(player.getIdentifier)
            if ok then value = result end
        end
        value = value or player.identifier
        return normalizeId(value)
    end
    return nil
end

function NovaCarRadioFramework.getPlayerName(src)
    local framework = NovaCarRadioFramework.refresh(false)
    if framework == 'nova' and core and core.Functions then
        local F = core.Functions
        local player = type(F.GetPlayer) == 'function' and F.GetPlayer(src) or nil
        local identity = player and player.PlayerData and player.PlayerData.identity or {}
        local name = (('%s %s'):format(identity.firstName or '', identity.lastName or '')):gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' then return name end
    elseif framework == 'qbcore' then
        local player = qbPlayer(src)
        local info = player and player.PlayerData and player.PlayerData.charinfo or {}
        local name = (('%s %s'):format(info.firstname or '', info.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' then return name end
    elseif framework == 'esx' then
        local player = esxPlayer(src)
        if player and type(player.getName) == 'function' then
            local ok, name = pcall(player.getName)
            if ok and type(name) == 'string' and name ~= '' then return name end
        end
        if player and type(player.name) == 'string' and player.name ~= '' then return player.name end
    end
    return GetPlayerName(src) or ('Player '..tostring(src))
end

function NovaCarRadioFramework.registerServerCallback(name, handler)
    if type(name) ~= 'string' or type(handler) ~= 'function' then return false end
    local framework = NovaCarRadioFramework.refresh(false)
    if callbacks[name] == framework then return true end

    local registered = false
    if framework == 'nova' and core and core.Functions and type(core.Functions.CreateCallback) == 'function' then
        core.Functions.CreateCallback(name, handler)
        registered = true
    elseif framework == 'qbcore' and core and core.Functions and type(core.Functions.CreateCallback) == 'function' then
        core.Functions.CreateCallback(name, handler)
        registered = true
    elseif framework == 'esx' and core and type(core.RegisterServerCallback) == 'function' then
        core.RegisterServerCallback(name, handler)
        registered = true
    end

    if registered then callbacks[name] = framework end
    return registered
end

function NovaCarRadioFramework.removeServerCallback(name)
    local framework = callbacks[name] or NovaCarRadioFramework.refresh(false)
    if framework == 'nova' and core and core.Functions and type(core.Functions.RemoveCallback) == 'function' then
        pcall(core.Functions.RemoveCallback, name)
    elseif framework == 'qbcore' and core and type(core.ServerCallbacks) == 'table' then
        core.ServerCallbacks[name] = nil
    end
    callbacks[name] = nil
end

AddEventHandler('onResourceStart', function(name)
    if not NovaCarRadioFramework.isFrameworkResource(name) then return end
    CreateThread(function()
        Wait(250)
        NovaCarRadioFramework.refresh(true)
    end)
end)

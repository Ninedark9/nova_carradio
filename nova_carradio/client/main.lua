local Config = NovaCarRadioConfig
local radioStates = {}
local queues = {}
local appliedTokens = {}
local appliedLocalVolumes = {}
local pending = {}
local sequence = 0
local uiOpen = false
local uiVehicleNetId = nil

local function notify(text, kind)
    if NovaCarRadioFramework and type(NovaCarRadioFramework.notify) == 'function' then
        NovaCarRadioFramework.notify(text, kind, 3500)
    end
end

local function soundName(netId)
    return ('nova_carradio_%s'):format(tostring(netId))
end

local function oliExists(name)
    if GetResourceState('olisound') ~= 'started' then return false end
    local ok, result = pcall(function() return exports['olisound']:soundExists(name) end)
    return ok and result == true
end

local function destroyOli(netId)
    local name = soundName(netId)
    if oliExists(name) then pcall(function() exports['olisound']:Destroy(name) end) end
end

local function destroySoundCloud(netId)
    SendNUIMessage({ action = 'sc:destroy', id = soundName(netId) })
end

local function entityFromNet(netId)
    if not NetworkDoesNetworkIdExist(netId) then return 0 end
    local entity = NetToVeh(netId)
    if entity ~= 0 and DoesEntityExist(entity) then return entity end
    return 0
end

local function clamp(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function boostedOliVolume(state, entity)
    local base = clamp(state and state.volume or Config.DefaultVolume, 0.0, tonumber(Config.MaxVolume) or 1.0)
    local ped = PlayerPedId()
    local myVehicle = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    local boost = tonumber(Config.OutsideGainBoost) or 1.0
    if entity and entity ~= 0 and myVehicle == entity then
        boost = tonumber(Config.InsideGainBoost) or 2.25
    elseif myVehicle ~= 0 then
        boost = tonumber(Config.OtherVehicleGainBoost) or 0.90
    end
    return clamp(base * boost, 0.0, tonumber(Config.MaxOliGain) or 3.0)
end

local function applyDjEffects(name, state)
    if not state or GetResourceState('olisound') ~= 'started' then return end
    local fx = type(state.effects) == 'table' and state.effects or {}
    local bass = clamp(fx.bass or 0, 0, 100)
    local reverb = clamp(fx.reverb or 0, 0, 100) / 100.0
    local distortion = clamp(fx.distortion or 0, 0, 100) / 100.0
    local tempoMin = tonumber(Config.DJ and Config.DJ.TempoMin) or 0.75
    local tempoMax = tonumber(Config.DJ and Config.DJ.TempoMax) or 1.25
    local tempo = clamp(fx.tempo or 1.0, tempoMin, tempoMax)

    pcall(function() exports['olisound']:setReverb(name, reverb) end)
    pcall(function() exports['olisound']:setDistortion(name, distortion) end)
    pcall(function() exports['olisound']:setPlaybackRate(name, tempo) end)

    if bass <= 0.5 then
        pcall(function() exports['olisound']:setMuffled(name, false) end)
    else
        local minHz = tonumber(Config.DJ and Config.DJ.BassMinFrequency) or 3200
        local maxHz = tonumber(Config.DJ and Config.DJ.BassMaxFrequency) or 20000
        local hz = maxHz - ((bass / 100.0) * (maxHz - minHz))
        pcall(function() exports['olisound']:setMuffled(name, true, math.floor(hz)) end)
    end
end

local function applyOliState(netId, state, entity)
    local name = soundName(netId)
    destroySoundCloud(netId)

    local tokenChanged = appliedTokens[netId] ~= state.token
    if tokenChanged or not oliExists(name) then
        destroyOli(netId)
        local options = {
            onPlayStart = function()
                if tonumber(state.position) and tonumber(state.position) > 0.8 then
                    pcall(function() exports['olisound']:setTimeStamp(name, tonumber(state.position)) end)
                end
                if not state.playing then pcall(function() exports['olisound']:Pause(name) end) end
                applyDjEffects(name, state)
            end,
            onPlayEnd = function()
                TriggerServerEvent('nova_carradio:server:ended', netId, state.token)
            end,
            onError = function(info)
                print(('^1[NOVA CARRADIO] Audio error %s: %s^7'):format(name, json.encode(info or {})))
            end
        }
        local ok, err = pcall(function()
            exports['olisound']:PlayUrlVehicle(name, state.url, boostedOliVolume(state, entity), entity, state.loop == true, options)
        end)
        if not ok then
            print(('^1[NOVA CARRADIO] Failed to start oliSound: %s^7'):format(tostring(err)))
            return
        end
        pcall(function() exports['olisound']:Distance(name, tonumber(Config.HearingDistance) or 22.0) end)
        applyDjEffects(name, state)
        appliedTokens[netId] = state.token
    else
        pcall(function() exports['olisound']:setVolumeMax(name, boostedOliVolume(state, entity)) end)
        pcall(function() exports['olisound']:setSoundLoop(name, state.loop == true) end)
        applyDjEffects(name, state)
        local playing = false
        local okPlaying, result = pcall(function() return exports['olisound']:isPlaying(name) end)
        if okPlaying then playing = result == true end
        if state.playing and not playing then pcall(function() exports['olisound']:Resume(name) end)
        elseif not state.playing and playing then pcall(function() exports['olisound']:Pause(name) end) end
    end
end

local function applySoundCloudState(netId, state, entity)
    destroyOli(netId)
    local tokenChanged = appliedTokens[netId] ~= state.token
    if tokenChanged then
        SendNUIMessage({
            action = 'sc:create',
            id = soundName(netId),
            url = state.url,
            volume = 0,
            position = tonumber(state.position) or 0,
            playing = state.playing == true,
            loop = state.loop == true,
            token = state.token,
        })
        appliedTokens[netId] = state.token
    else
        SendNUIMessage({ action = state.playing and 'sc:resume' or 'sc:pause', id = soundName(netId) })
    end
end

local function clearState(netId)
    destroyOli(netId)
    destroySoundCloud(netId)
    radioStates[netId] = nil
    appliedTokens[netId] = nil
    appliedLocalVolumes[netId] = nil
    if uiOpen and uiVehicleNetId == netId then
        SendNUIMessage({ action = 'radioState', state = nil })
    end
end

local function reconcileRadio(netId)
    local state = radioStates[netId]
    if not state then return clearState(netId) end
    local entity = entityFromNet(netId)
    if entity == 0 then return end
    if state.provider == 'soundcloud' then applySoundCloudState(netId, state, entity)
    else applyOliState(netId, state, entity) end
end

RegisterNetEvent('nova_carradio:client:state', function(netId, state)
    netId = tonumber(netId)
    if not netId then return end
    if not state then
        clearState(netId)
        return
    end
    radioStates[netId] = state
    reconcileRadio(netId)
    if uiOpen and uiVehicleNetId == netId then
        SendNUIMessage({ action = 'radioState', state = state })
    end
end)

RegisterNetEvent('nova_carradio:client:snapshot', function(states)
    states = type(states) == 'table' and states or {}
    for key, state in pairs(states) do
        local netId = tonumber(key)
        if netId and type(state) == 'table' then radioStates[netId] = state end
    end
end)

RegisterNetEvent('nova_carradio:client:queue', function(netId, queue)
    netId = tonumber(netId)
    if not netId then return end
    queues[netId] = type(queue) == 'table' and queue or {}
    if uiOpen and uiVehicleNetId == netId then SendNUIMessage({ action = 'queue', queue = queues[netId] }) end
end)

RegisterNetEvent('nova_carradio:client:response', function(requestId, data, err)
    if source ~= 65535 then return end
    local p = pending[requestId]
    if not p then return end
    pending[requestId] = nil
    p:resolve({ data = data, err = err })
end)

local function request(action, payload)
    sequence = sequence + 1
    if sequence > 2147483000 then sequence = 1 end
    local id = ('radio:%d:%d'):format(GetGameTimer(), sequence)
    local p = promise.new()
    pending[id] = p
    TriggerServerEvent('nova_carradio:server:request', id, action, payload)
    SetTimeout(10000, function()
        local waiter = pending[id]
        if waiter then
            pending[id] = nil
            waiter:resolve({ data = nil, err = 'Car radio request timed out.' })
        end
    end)
    local result = Citizen.Await(p)
    return result and result.data or nil, result and result.err or 'Car radio request failed.'
end

local function currentVehicle()
    local ped = PlayerPedId()
    if ped == 0 then return 0, 0 end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then return 0, 0 end
    return vehicle, VehToNet(vehicle)
end

local function closeUi()
    if not uiOpen then return end
    uiOpen = false
    uiVehicleNetId = nil
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'close' })
end

local function openUi()
    if uiOpen then return end
    local vehicle, netId = currentVehicle()
    if vehicle == 0 or netId == 0 then
        notify('You must be inside a vehicle to use /carradio.', 'error')
        return
    end
    CreateThread(function()
        local data, err = request('open', {})
        if not data then notify(err or 'Unable to open car radio.', 'error'); return end
        uiOpen = true
        uiVehicleNetId = netId
        queues[netId] = data.queue or {}
        data.vehicle = type(data.vehicle) == 'table' and data.vehicle or {}
        local displayKey = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
        local displayName = displayKey and GetLabelText(displayKey) or nil
        if not displayName or displayName == 'NULL' or displayName == '' then displayName = displayKey or 'VEHICLE' end
        data.vehicle.display = displayName
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(false)
        SendNUIMessage({ action = 'open', data = data })
    end)
end

RegisterCommand(Config.Command or 'carradio', openUi, false)
CreateThread(function()
    Wait(800)
    TriggerEvent('chat:addSuggestion', '/'..(Config.Command or 'carradio'), 'Open the advanced vehicle radio (vehicle only).')
    TriggerServerEvent('nova_carradio:server:requestSnapshot')
end)

local function nuiAction(action, payload, cb)
    CreateThread(function()
        local data, err = request(action, payload or {})
        if not data then cb({ ok = false, error = err }); notify(err or 'Radio request failed.', 'error'); return end
        if data.state ~= nil and uiVehicleNetId then radioStates[uiVehicleNetId] = data.state end
        if data.queue and uiVehicleNetId then queues[uiVehicleNetId] = data.queue end
        SendNUIMessage({ action = 'actionResult', request = action, data = data })
        cb({ ok = true, data = data })
    end)
end

RegisterNUICallback('close', function(_, cb) closeUi(); cb({ ok = true }) end)
RegisterNUICallback('play', function(payload, cb) nuiAction('play', payload, cb) end)
RegisterNUICallback('queueAdd', function(payload, cb) nuiAction('queueAdd', payload, cb) end)
RegisterNUICallback('queueRemove', function(payload, cb) nuiAction('queueRemove', payload, cb) end)
RegisterNUICallback('queuePlay', function(payload, cb) nuiAction('queuePlay', payload, cb) end)
RegisterNUICallback('next', function(payload, cb) nuiAction('next', payload, cb) end)
RegisterNUICallback('previous', function(payload, cb) nuiAction('previous', payload, cb) end)
RegisterNUICallback('pause', function(payload, cb) nuiAction('pause', payload, cb) end)
RegisterNUICallback('resume', function(payload, cb) nuiAction('resume', payload, cb) end)
RegisterNUICallback('stop', function(payload, cb) nuiAction('stop', payload, cb) end)
RegisterNUICallback('volume', function(payload, cb) nuiAction('volume', payload, cb) end)
RegisterNUICallback('seek', function(payload, cb) nuiAction('seek', payload, cb) end)
RegisterNUICallback('loop', function(payload, cb) nuiAction('loop', payload, cb) end)
RegisterNUICallback('effects', function(payload, cb) nuiAction('effects', payload, cb) end)
RegisterNUICallback('favorite', function(payload, cb) nuiAction('favorite', payload, cb) end)
RegisterNUICallback('playlistCreate', function(payload, cb) nuiAction('playlistCreate', payload, cb) end)
RegisterNUICallback('playlistRename', function(payload, cb) nuiAction('playlistRename', payload, cb) end)
RegisterNUICallback('playlistDelete', function(payload, cb) nuiAction('playlistDelete', payload, cb) end)
RegisterNUICallback('playlistAdd', function(payload, cb) nuiAction('playlistAdd', payload, cb) end)
RegisterNUICallback('playlistRemoveTrack', function(payload, cb) nuiAction('playlistRemoveTrack', payload, cb) end)
RegisterNUICallback('playlistPlay', function(payload, cb) nuiAction('playlistPlay', payload, cb) end)
RegisterNUICallback('playlistTrackPlay', function(payload, cb) nuiAction('playlistTrackPlay', payload, cb) end)

RegisterNUICallback('soundcloudEnded', function(payload, cb)
    local id = tostring(payload and payload.id or '')
    local netId = tonumber(id:match('nova_carradio_(%d+)'))
    local state = netId and radioStates[netId] or nil
    if state then TriggerServerEvent('nova_carradio:server:ended', netId, state.token) end
    cb({ ok = true })
end)

local function vehicleOpenEnough(vehicle)
    for door = 0, 5 do
        if GetVehicleDoorAngleRatio(vehicle, door) > 0.08 then return true end
    end
    for window = 0, 3 do
        if not IsVehicleWindowIntact(vehicle, window) then return true end
    end
    return false
end

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local pcoords = ped ~= 0 and GetEntityCoords(ped) or vector3(0.0,0.0,0.0)
        local myVehicle = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
        local maxDistance = tonumber(Config.HearingDistance) or 22.0
        local count = 0

        for netId, state in pairs(radioStates) do
            local vehicle = entityFromNet(netId)
            if vehicle ~= 0 then
                local distance = #(pcoords - GetEntityCoords(vehicle))
                if distance <= maxDistance + 5.0 then
                    count = count + 1
                    if count <= (tonumber(Config.MaxNearbyRadios) or 8) then
                        if appliedTokens[netId] ~= state.token then reconcileRadio(netId) end
                        if state.provider == 'soundcloud' then
                            local base = math.max(0.0, math.min(1.0, tonumber(state.volume) or Config.DefaultVolume))
                            local gain = 1.0
                            if myVehicle == vehicle then
                                gain = 1.0
                            else
                                local distanceGain = math.max(0.0, 1.0 - (distance / maxDistance))
                                distanceGain = distanceGain * distanceGain
                                local openCabin = vehicleOpenEnough(vehicle)
                                local multiplier = openCabin and (Config.SoundCloud.OutsideOpenMultiplier or 0.58) or (Config.SoundCloud.OutsideClosedMultiplier or 0.28)
                                if myVehicle ~= 0 then multiplier = multiplier * (Config.SoundCloud.OtherVehicleMultiplier or 0.20) end
                                gain = distanceGain * multiplier
                            end
                            SendNUIMessage({ action = 'sc:volume', id = soundName(netId), volume = math.floor(base * gain * 100 + 0.5) })
                        else
                            local name = soundName(netId)
                            if oliExists(name) then
                                local targetVolume = boostedOliVolume(state, vehicle)
                                local previousVolume = appliedLocalVolumes[netId]
                                if not previousVolume or math.abs(previousVolume - targetVolume) > 0.01 then
                                    appliedLocalVolumes[netId] = targetVolume
                                    pcall(function() exports['olisound']:setVolumeMax(name, targetVolume) end)
                                end
                            end
                        end
                    end
                end
            end
        end
        Wait(tonumber(Config.SoundCloudUpdateMs) or 180)
    end
end)

CreateThread(function()
    while true do
        if uiOpen then
            local vehicle, netId = currentVehicle()
            if vehicle == 0 or netId ~= uiVehicleNetId then
                closeUi()
            else
                local state = radioStates[netId]
                if state and state.provider ~= 'soundcloud' then
                    local name = soundName(netId)
                    local position, duration = tonumber(state.position) or 0, 0
                    if oliExists(name) then
                        local okP, p = pcall(function() return exports['olisound']:getTimeStamp(name) end)
                        local okD, d = pcall(function() return exports['olisound']:getMaxDuration(name) end)
                        if okP and tonumber(p) then position = tonumber(p) end
                        if okD and tonumber(d) then duration = tonumber(d) end
                    end
                    SendNUIMessage({ action = 'progress', position = position, duration = duration })
                end
                if Config.DisableNativeRadio then
                    SetVehRadioStation(vehicle, 'OFF')
                    SetVehicleRadioEnabled(vehicle, false)
                end
            end
            Wait(tonumber(Config.UiUpdateMs) or 250)
        else
            Wait(500)
        end
    end
end)

CreateThread(function()
    while true do
        if Config.DisableNativeRadio then
            local vehicle, netId = currentVehicle()
            if vehicle ~= 0 and radioStates[netId] then
                SetVehRadioStation(vehicle, 'OFF')
                SetVehicleRadioEnabled(vehicle, false)
                Wait(0)
            else
                Wait(400)
            end
        else
            Wait(1000)
        end
    end
end)

AddEventHandler('onClientResourceStart', function(name)
    if NovaCarRadioFramework and NovaCarRadioFramework.isFrameworkResource(name) then
        Wait(300)
        NovaCarRadioFramework.refresh(true)
    end
    if name == 'olisound' or name == GetCurrentResourceName() then
        Wait(500)
        if NovaCarRadioFramework then NovaCarRadioFramework.refresh(true) end
        TriggerServerEvent('nova_carradio:server:requestSnapshot')
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    closeUi()
    for netId in pairs(radioStates) do
        destroyOli(netId)
        destroySoundCloud(netId)
    end
end)

exports('OpenCarRadio', openUi)
exports('GetCurrentVehicleRadio', function()
    local _, netId = currentVehicle()
    return netId ~= 0 and radioStates[netId] or nil
end)

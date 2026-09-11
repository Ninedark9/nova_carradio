local Config = NovaCarRadioConfig
local radios = {}
local queues = {}
local previousTracks = {}
local requestRate = {}
local databaseReady = false

math.randomseed(os.time())

local function getCharacterId(src)
    return NovaCarRadioFramework.getCharacterId(src)
end

local function getPlayerName(src)
    return NovaCarRadioFramework.getPlayerName(src)
end

local function setupDatabase()
    if not (Config.Database and Config.Database.Enabled) then
        databaseReady = true
        return
    end
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_carradio_history` (
            `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            `character_id` VARCHAR(128) NOT NULL,
            `url` VARCHAR(700) NOT NULL,
            `provider` VARCHAR(20) NOT NULL DEFAULT 'direct',
            `title` VARCHAR(200) NOT NULL DEFAULT '',
            `author` VARCHAR(160) NOT NULL DEFAULT '',
            `artwork` VARCHAR(700) NOT NULL DEFAULT '',
            `created_at` BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_nova_carradio_history_character` (`character_id`, `id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_carradio_favorites` (
            `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            `character_id` VARCHAR(128) NOT NULL,
            `url` VARCHAR(700) NOT NULL,
            `provider` VARCHAR(20) NOT NULL DEFAULT 'direct',
            `title` VARCHAR(200) NOT NULL DEFAULT '',
            `author` VARCHAR(160) NOT NULL DEFAULT '',
            `artwork` VARCHAR(700) NOT NULL DEFAULT '',
            `created_at` BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_nova_carradio_favorites_character` (`character_id`, `id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_carradio_playlists` (
            `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            `character_id` VARCHAR(128) NOT NULL,
            `name` VARCHAR(60) NOT NULL,
            `created_at` BIGINT UNSIGNED NOT NULL,
            `updated_at` BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_nova_carradio_playlists_character` (`character_id`, `id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `nova_carradio_playlist_tracks` (
            `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            `playlist_id` BIGINT UNSIGNED NOT NULL,
            `url` VARCHAR(700) NOT NULL,
            `provider` VARCHAR(20) NOT NULL DEFAULT 'direct',
            `title` VARCHAR(200) NOT NULL DEFAULT '',
            `author` VARCHAR(160) NOT NULL DEFAULT '',
            `artwork` VARCHAR(700) NOT NULL DEFAULT '',
            `position` INT UNSIGNED NOT NULL DEFAULT 1,
            `created_at` BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_nova_carradio_playlist_tracks_playlist` (`playlist_id`, `position`, `id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])

    local function ensureCharacterIdWidth(tableName)
        local column = MySQL.single.await([[
            SELECT `CHARACTER_MAXIMUM_LENGTH` AS `maxLength`
            FROM `information_schema`.`COLUMNS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = ? AND `COLUMN_NAME` = 'character_id'
            LIMIT 1
        ]], { tableName })
        if column and tonumber(column.maxLength) and tonumber(column.maxLength) < 128 then
            MySQL.query.await(('ALTER TABLE `%s` MODIFY `character_id` VARCHAR(128) NOT NULL'):format(tableName))
        end
    end
    ensureCharacterIdWidth('nova_carradio_history')
    ensureCharacterIdWidth('nova_carradio_favorites')
    ensureCharacterIdWidth('nova_carradio_playlists')
    databaseReady = true
end

CreateThread(function()
    Wait(500)
    NovaCarRadioFramework.refresh(true)
    if Config.Database and Config.Database.AutoCreate ~= false then
        while not databaseReady do
            local ok, err = pcall(setupDatabase)
            if not ok then
                print('^1[NOVA CARRADIO] Database setup failed: '..tostring(err)..'^7')
                Wait(5000)
            end
        end
    else
        databaseReady = true
    end
end)

local function urlEncode(value)
    return (tostring(value or ''):gsub('\n', '\r\n'):gsub('([^%w%-_%.~])', function(c)
        return string.format('%%%02X', string.byte(c))
    end))
end

local function validUrl(url)
    url = clean(url, tonumber(Config.MaxUrlLength) or 700)
    if #url < 8 then return nil, 'Enter a valid URL.' end
    if not url:match('^https://') and not url:match('^http://') then return nil, 'Only HTTP/HTTPS links are allowed.' end
    if url:match('^http://127%.') or url:match('^http://localhost') or url:match('^https://localhost') then
        return nil, 'Local URLs are not allowed.'
    end
    return url
end

local function detectProvider(url)
    local lower = tostring(url or ''):lower()
    if lower:find('youtube%.com', 1, false) or lower:find('youtu%.be', 1, false) or lower:find('youtube%-nocookie%.com', 1, false) then
        return 'youtube'
    end
    if lower:find('soundcloud%.com', 1, false) then return 'soundcloud' end
    return 'direct'
end

local function httpJson(url, timeoutMs)
    local p = promise.new()
    local done = false
    PerformHttpRequest(url, function(statusCode, body)
        if done then return end
        done = true
        if statusCode and statusCode >= 200 and statusCode < 300 and type(body) == 'string' then
            local ok, parsed = pcall(json.decode, body)
            p:resolve(ok and parsed or nil)
        else
            p:resolve(nil)
        end
    end, 'GET', '', { ['Accept'] = 'application/json' })
    SetTimeout(timeoutMs or 7000, function()
        if done then return end
        done = true
        p:resolve(nil)
    end)
    return Citizen.Await(p)
end

local function fileTitle(url)
    local value = tostring(url or ''):gsub('%?.*$', '')
    value = value:match('/([^/]+)$') or 'Audio stream'
    value = value:gsub('%%20', ' '):gsub('%.[%w%d]+$', '')
    return clean(value, 200)
end

local function resolveMetadata(url)
    local provider = detectProvider(url)
    local result = {
        url = url,
        provider = provider,
        title = provider == 'youtube' and 'YouTube audio' or provider == 'soundcloud' and 'SoundCloud track' or fileTitle(url),
        author = provider == 'direct' and 'Direct stream' or '',
        artwork = ''
    }

    local endpoint = nil
    if provider == 'youtube' then
        endpoint = 'https://www.youtube.com/oembed?format=json&url='..urlEncode(url)
    elseif provider == 'soundcloud' then
        endpoint = 'https://soundcloud.com/oembed?format=json&url='..urlEncode(url)
    end

    if endpoint then
        local data = httpJson(endpoint, 7000)
        if type(data) == 'table' then
            result.title = clean(data.title or result.title, 200)
            result.author = clean(data.author_name or result.author, 160)
            result.artwork = clean(data.thumbnail_url or '', 700)
        end
    end
    return result
end

local function vehicleForSource(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil, nil, 'Player entity is unavailable.' end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if not vehicle or vehicle == 0 then return nil, nil, 'You must be inside a vehicle to use the car radio.' end
    if Config.DriverOnly and GetPedInVehicleSeat(vehicle, -1) ~= ped then
        return nil, nil, 'Only the driver can control the radio.'
    end
    if Config.AllowPassengers == false and GetPedInVehicleSeat(vehicle, -1) ~= ped then
        return nil, nil, 'Passengers cannot control the radio.'
    end
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if not netId or netId == 0 then return nil, nil, 'Vehicle is not networked.' end
    return vehicle, netId
end

local function vehicleInfo(vehicle, netId)
    return {
        netId = netId,
        plate = clean(GetVehicleNumberPlateText(vehicle) or '', 16),
        model = GetEntityModel(vehicle),
        display = 'VEHICLE',
    }
end

local function now() return os.time() end

local function currentPosition(state)
    if not state then return 0 end
    local position = math.max(0, tonumber(state.position) or 0)
    if state.playing and tonumber(state.startedAt) then
        position = position + math.max(0, now() - tonumber(state.startedAt))
    end
    return position
end

local function trackEntryFromState(state)
    if type(state) ~= 'table' then return nil end
    return {
        url = state.url,
        provider = state.provider,
        title = state.title,
        author = state.author,
        artwork = state.artwork,
    }
end

local function pushPrevious(netId, state)
    local entry = trackEntryFromState(state)
    if not entry then return end
    local stack = previousTracks[netId] or {}
    stack[#stack + 1] = entry
    local maxPrev = math.max(1, math.min(50, tonumber(Config.HistoryLimit) or 20))
    while #stack > maxPrev do table.remove(stack, 1) end
    previousTracks[netId] = stack
end

local function clamp(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function normalizeEffects(value)
    local defaults = (Config.DJ and Config.DJ.Default) or {}
    value = type(value) == 'table' and value or {}
    return {
        bass = clamp(value.bass ~= nil and value.bass or defaults.bass or 0, 0, 100),
        reverb = clamp(value.reverb ~= nil and value.reverb or defaults.reverb or 0, 0, 100),
        distortion = clamp(value.distortion ~= nil and value.distortion or defaults.distortion or 0, 0, 100),
        tempo = clamp(value.tempo ~= nil and value.tempo or defaults.tempo or 1.0, tonumber(Config.DJ and Config.DJ.TempoMin) or 0.75, tonumber(Config.DJ and Config.DJ.TempoMax) or 1.25),
    }
end

local function statePublic(state)
    if type(state) ~= 'table' then return nil end
    return {
        netId = state.netId,
        url = state.url,
        provider = state.provider,
        title = state.title,
        author = state.author,
        artwork = state.artwork,
        volume = state.volume,
        loop = state.loop,
        playing = state.playing,
        position = currentPosition(state),
        startedAt = state.playing and now() or nil,
        token = state.token,
        updatedAt = state.updatedAt,
        controller = state.controllerName,
        hasPrevious = previousTracks[state.netId] and #previousTracks[state.netId] > 0 or false,
        effects = normalizeEffects(state.effects),
    }
end

local function publish(netId)
    local state = radios[netId]
    local public = statePublic(state)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        pcall(function() Entity(entity).state:set('nova:carradio', public, true) end)
    end
    TriggerClientEvent('nova_carradio:client:state', -1, netId, public)
end

local function newToken()
    return ('%d-%06d'):format(now(), math.random(0, 999999))
end

local function addHistory(src, entry)
    if not databaseReady or not (Config.Database and Config.Database.Enabled) then return end
    local characterId = getCharacterId(src)
    if not characterId then return end
    pcall(MySQL.insert.await, [[
        INSERT INTO `nova_carradio_history`
        (`character_id`,`url`,`provider`,`title`,`author`,`artwork`,`created_at`)
        VALUES (?,?,?,?,?,?,?)
    ]], { characterId, entry.url, entry.provider, entry.title, entry.author, entry.artwork, now() })
end

local function loadHistory(src)
    if not databaseReady or not (Config.Database and Config.Database.Enabled) then return {} end
    local characterId = getCharacterId(src)
    if not characterId then return {} end
    local limit = math.max(1, math.min(100, tonumber(Config.HistoryLimit) or 20))
    local ok, rows = pcall(MySQL.query.await, ('SELECT `id`,`url`,`provider`,`title`,`author`,`artwork`,`created_at` FROM `nova_carradio_history` WHERE `character_id` = ? ORDER BY `id` DESC LIMIT %d'):format(limit), { characterId })
    return ok and type(rows) == 'table' and rows or {}
end

local function loadFavorites(src)
    if not databaseReady or not (Config.Database and Config.Database.Enabled) then return {} end
    local characterId = getCharacterId(src)
    if not characterId then return {} end
    local limit = math.max(1, math.min(100, tonumber(Config.FavoritesLimit) or 40))
    local ok, rows = pcall(MySQL.query.await, ('SELECT `id`,`url`,`provider`,`title`,`author`,`artwork`,`created_at` FROM `nova_carradio_favorites` WHERE `character_id` = ? ORDER BY `id` DESC LIMIT %d'):format(limit), { characterId })
    return ok and type(rows) == 'table' and rows or {}
end

local function normalizePlaylistUrls(value)
    local out, seen = {}, {}
    local maxAdd = math.max(1, math.min(50, tonumber(Config.PlaylistBulkAddLimit) or 20))
    local function push(raw)
        if #out >= maxAdd then return end
        local url = trim(raw)
        if url ~= '' and not seen[url] then
            local valid = validUrl(url)
            if valid then
                seen[valid] = true
                out[#out+1] = valid
            end
        end
    end
    if type(value) == 'table' then
        for _, raw in ipairs(value) do push(raw) end
    elseif type(value) == 'string' then
        for raw in value:gmatch('[^\r\n]+') do push(raw) end
    end
    return out
end

local function playlistOwned(characterId, playlistId)
    playlistId = math.floor(tonumber(playlistId) or 0)
    if playlistId < 1 then return nil end
    local ok, row = pcall(MySQL.single.await, 'SELECT `id`,`name` FROM `nova_carradio_playlists` WHERE `id` = ? AND `character_id` = ? LIMIT 1', { playlistId, characterId })
    return ok and row or nil
end

local function loadPlaylistTracks(playlistId)
    local limit = math.max(1, math.min(100, tonumber(Config.PlaylistTrackLimit) or 50))
    local ok, rows = pcall(MySQL.query.await, ('SELECT `id`,`url`,`provider`,`title`,`author`,`artwork`,`position`,`created_at` FROM `nova_carradio_playlist_tracks` WHERE `playlist_id` = ? ORDER BY `position` ASC, `id` ASC LIMIT %d'):format(limit), { playlistId })
    return ok and type(rows) == 'table' and rows or {}
end

local function loadPlaylists(src)
    if not databaseReady or not (Config.Database and Config.Database.Enabled) then return {} end
    local characterId = getCharacterId(src)
    if not characterId then return {} end
    local limit = math.max(1, math.min(50, tonumber(Config.PlaylistLimit) or 20))
    local ok, rows = pcall(MySQL.query.await, ('SELECT `id`,`name`,`created_at`,`updated_at` FROM `nova_carradio_playlists` WHERE `character_id` = ? ORDER BY `updated_at` DESC, `id` DESC LIMIT %d'):format(limit), { characterId })
    if not ok or type(rows) ~= 'table' then return {} end
    for _, playlist in ipairs(rows) do
        playlist.tracks = loadPlaylistTracks(playlist.id)
        playlist.trackCount = #playlist.tracks
    end
    return rows
end

local function addTracksToPlaylist(characterId, playlistId, urls)
    local owned = playlistOwned(characterId, playlistId)
    if not owned then return nil, 'Playlist not found.' end
    local tracks = loadPlaylistTracks(playlistId)
    local maxTracks = math.max(1, math.min(100, tonumber(Config.PlaylistTrackLimit) or 50))
    local available = maxTracks - #tracks
    if available <= 0 then return nil, 'Playlist track limit reached.' end
    urls = normalizePlaylistUrls(urls)
    if #urls == 0 then return nil, 'Add at least one valid HTTP/HTTPS link.' end
    local added = 0
    local position = #tracks
    for _, url in ipairs(urls) do
        if added >= available then break end
        local duplicate = MySQL.single.await('SELECT `id` FROM `nova_carradio_playlist_tracks` WHERE `playlist_id` = ? AND `url` = ? LIMIT 1', { playlistId, url })
        if not duplicate then
            local entry = resolveMetadata(url)
            position = position + 1
            MySQL.insert.await('INSERT INTO `nova_carradio_playlist_tracks` (`playlist_id`,`url`,`provider`,`title`,`author`,`artwork`,`position`,`created_at`) VALUES (?,?,?,?,?,?,?,?)',
                { playlistId, entry.url, entry.provider, entry.title, entry.author, entry.artwork, position, now() })
            added = added + 1
        end
    end
    MySQL.update.await('UPDATE `nova_carradio_playlists` SET `updated_at` = ? WHERE `id` = ? AND `character_id` = ?', { now(), playlistId, characterId })
    return added
end

local function startEntry(src, netId, entry, volume, loop, opts)
    opts = type(opts) == 'table' and opts or {}
    local previousState = radios[netId]
    local effects = normalizeEffects(opts.effects or (previousState and previousState.effects) or nil)
    if previousState and not opts.skipHistory then pushPrevious(netId, previousState) end
    radios[netId] = {
        netId = netId,
        url = entry.url,
        provider = entry.provider,
        title = entry.title,
        author = entry.author,
        artwork = entry.artwork,
        volume = math.max(0.0, math.min(tonumber(Config.MaxVolume) or 1.0, tonumber(volume) or tonumber(Config.DefaultVolume) or 0.55)),
        loop = loop == true,
        playing = true,
        position = 0,
        startedAt = now(),
        updatedAt = now(),
        token = newToken(),
        controller = src,
        controllerName = getPlayerName(src),
        effects = effects,
    }
    publish(netId)
    addHistory(src, entry)
    return statePublic(radios[netId])
end

local function consumeQueue(src, netId, index)
    local queue = queues[netId] or {}
    index = math.floor(tonumber(index) or 1)
    if index < 1 or index > #queue then return nil, 'Queue entry not found.' end
    local entry = table.remove(queue, index)
    queues[netId] = queue
    local old = radios[netId]
    return startEntry(src, netId, entry, old and old.volume or Config.DefaultVolume, old and old.loop or false)
end

local actions = {}

actions.open = function(src)
    local vehicle, netId, err = vehicleForSource(src)
    if not vehicle then return nil, err end
    return {
        vehicle = vehicleInfo(vehicle, netId),
        state = statePublic(radios[netId]),
        queue = queues[netId] or {},
        favorites = loadFavorites(src),
        history = loadHistory(src),
        playlists = loadPlaylists(src),
        config = {
            maxVolume = tonumber(Config.MaxVolume) or 1.0,
            defaultVolume = tonumber(Config.DefaultVolume) or 0.55,
            soundCloudEnabled = Config.SoundCloud and Config.SoundCloud.Enabled == true,
            visualizerBars = tonumber(Config.Visualizer and Config.Visualizer.Bars) or 32,
            volumeStep = tonumber(Config.VolumeStep) or 0.05,
            playlistLimit = tonumber(Config.PlaylistLimit) or 20,
            playlistTrackLimit = tonumber(Config.PlaylistTrackLimit) or 50,
            hearingDistance = tonumber(Config.HearingDistance) or 22.0,
            djEnabled = Config.DJ and Config.DJ.Enabled ~= false,
            tempoMin = tonumber(Config.DJ and Config.DJ.TempoMin) or 0.75,
            tempoMax = tonumber(Config.DJ and Config.DJ.TempoMax) or 1.25,
        }
    }
end

actions.play = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    payload = type(payload) == 'table' and payload or {}
    local url, urlErr = validUrl(payload.url)
    if not url then return nil, urlErr end
    local provider = detectProvider(url)
    if provider == 'soundcloud' and not (Config.SoundCloud and Config.SoundCloud.Enabled) then
        return nil, 'SoundCloud playback is disabled on this server.'
    end
    local entry = resolveMetadata(url)
    local state = startEntry(src, netId, entry, payload.volume, payload.loop)
    return { state = state, queue = queues[netId] or {}, entry = entry }
end

actions.queueAdd = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    payload = type(payload) == 'table' and payload or {}
    local queue = queues[netId] or {}
    if #queue >= math.max(1, tonumber(Config.QueueLimit) or 20) then return nil, 'The radio queue is full.' end
    local url, urlErr = validUrl(payload.url)
    if not url then return nil, urlErr end
    if detectProvider(url) == 'soundcloud' and not (Config.SoundCloud and Config.SoundCloud.Enabled) then
        return nil, 'SoundCloud playback is disabled on this server.'
    end
    local entry = resolveMetadata(url)
    queue[#queue+1] = entry
    queues[netId] = queue
    TriggerClientEvent('nova_carradio:client:queue', -1, netId, queue)
    return { queue = queue, entry = entry }
end

actions.queueRemove = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local queue = queues[netId] or {}
    local index = math.floor(tonumber(type(payload) == 'table' and payload.index or payload) or 0)
    if index < 1 or index > #queue then return nil, 'Queue entry not found.' end
    table.remove(queue, index)
    queues[netId] = queue
    TriggerClientEvent('nova_carradio:client:queue', -1, netId, queue)
    return { queue = queue }
end

actions.queuePlay = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state, queueErr = consumeQueue(src, netId, type(payload) == 'table' and payload.index or payload)
    if not state then return nil, queueErr end
    TriggerClientEvent('nova_carradio:client:queue', -1, netId, queues[netId] or {})
    return { state = state, queue = queues[netId] or {} }
end

actions.pause = function(src)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state = radios[netId]
    if not state then return nil, 'Nothing is playing.' end
    state.position = currentPosition(state)
    state.playing = false
    state.startedAt = nil
    state.updatedAt = now()
    publish(netId)
    return { state = statePublic(state) }
end

actions.resume = function(src)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state = radios[netId]
    if not state then return nil, 'Nothing is loaded.' end
    if not state.playing then
        state.playing = true
        state.startedAt = now()
        state.updatedAt = now()
        publish(netId)
    end
    return { state = statePublic(state) }
end

actions.stop = function(src)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    radios[netId] = nil
    publish(netId)
    return { state = nil }
end

actions.volume = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state = radios[netId]
    if not state then return nil, 'Nothing is loaded.' end
    local value = tonumber(type(payload) == 'table' and payload.volume or payload)
    if not value then return nil, 'Invalid volume.' end
    state.volume = math.max(0.0, math.min(tonumber(Config.MaxVolume) or 1.0, value))
    state.updatedAt = now()
    publish(netId)
    return { state = statePublic(state) }
end

actions.seek = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state = radios[netId]
    if not state then return nil, 'Nothing is loaded.' end
    local value = tonumber(type(payload) == 'table' and payload.position or payload)
    if not value then return nil, 'Invalid timestamp.' end
    state.position = math.max(0, value)
    state.startedAt = state.playing and now() or nil
    state.updatedAt = now()
    state.token = newToken()
    publish(netId)
    return { state = statePublic(state) }
end

actions.loop = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state = radios[netId]
    if not state then return nil, 'Nothing is loaded.' end
    state.loop = type(payload) == 'table' and payload.loop == true or payload == true
    state.updatedAt = now()
    publish(netId)
    return { state = statePublic(state) }
end

actions.next = function(src)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state = radios[netId]
    if not state then return nil, 'Nothing is loaded.' end
    local queue = queues[netId] or {}
    if #queue > 0 then
        local nextState, queueErr = consumeQueue(src, netId, 1)
        if not nextState then return nil, queueErr end
        TriggerClientEvent('nova_carradio:client:queue', -1, netId, queues[netId] or {})
        return { state = nextState, queue = queues[netId] or {} }
    end
    pushPrevious(netId, state)
    radios[netId] = nil
    publish(netId)
    return { state = nil, queue = queue }
end

actions.previous = function(src)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    local state = radios[netId]
    local queue = queues[netId] or {}

    if state and currentPosition(state) > 5.0 then
        state.position = 0
        state.startedAt = state.playing and now() or nil
        state.updatedAt = now()
        state.token = newToken()
        publish(netId)
        return { state = statePublic(state), queue = queue }
    end

    local stack = previousTracks[netId] or {}
    if #stack < 1 then
        if state then
            state.position = 0
            state.startedAt = state.playing and now() or nil
            state.updatedAt = now()
            state.token = newToken()
            publish(netId)
            return { state = statePublic(state), queue = queue }
        end
        return nil, 'No previous track.'
    end

    local entry = table.remove(stack)
    previousTracks[netId] = stack

    if state then
        local currentEntry = trackEntryFromState(state)
        if currentEntry then
            table.insert(queue, 1, currentEntry)
            local maxQueue = math.max(1, tonumber(Config.QueueLimit) or 20)
            while #queue > maxQueue do table.remove(queue) end
            queues[netId] = queue
        end
    end

    local newState = startEntry(src, netId, entry, state and state.volume or Config.DefaultVolume, state and state.loop or false, { skipHistory = true })
    TriggerClientEvent('nova_carradio:client:queue', -1, netId, queues[netId] or {})
    return { state = newState, queue = queues[netId] or {} }
end

actions.effects = function(src, payload)
    local _, netId, err = vehicleForSource(src)
    if not netId then return nil, err end
    if not (Config.DJ and Config.DJ.Enabled ~= false) then return nil, 'DJ controls are disabled.' end
    local state = radios[netId]
    if not state then return nil, 'Nothing is loaded.' end
    state.effects = normalizeEffects(payload)
    state.updatedAt = now()
    publish(netId)
    return { state = statePublic(state) }
end

actions.favorite = function(src, payload)
    if not databaseReady or not (Config.Database and Config.Database.Enabled) then return nil, 'Favorites are disabled.' end
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    payload = type(payload) == 'table' and payload or {}
    local url, urlErr = validUrl(payload.url)
    if not url then return nil, urlErr end
    local existing = MySQL.single.await('SELECT `id` FROM `nova_carradio_favorites` WHERE `character_id` = ? AND `url` = ? LIMIT 1', { characterId, url })
    local favorited = false
    if existing then
        MySQL.update.await('DELETE FROM `nova_carradio_favorites` WHERE `id` = ? AND `character_id` = ?', { existing.id, characterId })
    else
        local favorites = loadFavorites(src)
        if #favorites >= math.max(1, tonumber(Config.FavoritesLimit) or 40) then return nil, 'Favorite limit reached.' end
        local entry = {
            url = url,
            provider = clean(payload.provider or detectProvider(url), 20),
            title = clean(payload.title or fileTitle(url), 200),
            author = clean(payload.author or '', 160),
            artwork = clean(payload.artwork or '', 700),
        }
        MySQL.insert.await('INSERT INTO `nova_carradio_favorites` (`character_id`,`url`,`provider`,`title`,`author`,`artwork`,`created_at`) VALUES (?,?,?,?,?,?,?)',
            { characterId, entry.url, entry.provider, entry.title, entry.author, entry.artwork, now() })
        favorited = true
    end
    return { favorites = loadFavorites(src), favorited = favorited, url = url }
end

actions.playlistCreate = function(src, payload)
    if not databaseReady or not (Config.Database and Config.Database.Enabled) then return nil, 'Playlists are disabled.' end
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    payload = type(payload) == 'table' and payload or {}
    local name = clean(payload.name, 60)
    if #name < 2 then return nil, 'Playlist name must have at least 2 characters.' end
    local playlists = loadPlaylists(src)
    if #playlists >= math.max(1, tonumber(Config.PlaylistLimit) or 20) then return nil, 'Playlist limit reached.' end
    local id = MySQL.insert.await('INSERT INTO `nova_carradio_playlists` (`character_id`,`name`,`created_at`,`updated_at`) VALUES (?,?,?,?)', { characterId, name, now(), now() })
    if not id then return nil, 'Could not create playlist.' end
    local urls = normalizePlaylistUrls(payload.urls)
    if #urls > 0 then addTracksToPlaylist(characterId, id, urls) end
    return { playlists = loadPlaylists(src), playlistId = id }
end

actions.playlistRename = function(src, payload)
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    payload = type(payload) == 'table' and payload or {}
    local playlistId = math.floor(tonumber(payload.playlistId) or 0)
    if not playlistOwned(characterId, playlistId) then return nil, 'Playlist not found.' end
    local name = clean(payload.name, 60)
    if #name < 2 then return nil, 'Playlist name must have at least 2 characters.' end
    MySQL.update.await('UPDATE `nova_carradio_playlists` SET `name` = ?, `updated_at` = ? WHERE `id` = ? AND `character_id` = ?', { name, now(), playlistId, characterId })
    return { playlists = loadPlaylists(src), playlistId = playlistId }
end

actions.playlistDelete = function(src, payload)
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    local playlistId = math.floor(tonumber(type(payload) == 'table' and payload.playlistId or payload) or 0)
    if not playlistOwned(characterId, playlistId) then return nil, 'Playlist not found.' end
    MySQL.update.await('DELETE FROM `nova_carradio_playlist_tracks` WHERE `playlist_id` = ?', { playlistId })
    MySQL.update.await('DELETE FROM `nova_carradio_playlists` WHERE `id` = ? AND `character_id` = ?', { playlistId, characterId })
    return { playlists = loadPlaylists(src) }
end

actions.playlistAdd = function(src, payload)
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    payload = type(payload) == 'table' and payload or {}
    local playlistId = math.floor(tonumber(payload.playlistId) or 0)
    local added, err = addTracksToPlaylist(characterId, playlistId, payload.urls)
    if added == nil then return nil, err end
    return { playlists = loadPlaylists(src), playlistId = playlistId, added = added }
end

actions.playlistRemoveTrack = function(src, payload)
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    payload = type(payload) == 'table' and payload or {}
    local playlistId = math.floor(tonumber(payload.playlistId) or 0)
    local trackId = math.floor(tonumber(payload.trackId) or 0)
    if not playlistOwned(characterId, playlistId) then return nil, 'Playlist not found.' end
    MySQL.update.await('DELETE FROM `nova_carradio_playlist_tracks` WHERE `id` = ? AND `playlist_id` = ?', { trackId, playlistId })
    local remaining = loadPlaylistTracks(playlistId)
    for index, track in ipairs(remaining) do
        MySQL.update.await('UPDATE `nova_carradio_playlist_tracks` SET `position` = ? WHERE `id` = ? AND `playlist_id` = ?', { index, track.id, playlistId })
    end
    MySQL.update.await('UPDATE `nova_carradio_playlists` SET `updated_at` = ? WHERE `id` = ? AND `character_id` = ?', { now(), playlistId, characterId })
    return { playlists = loadPlaylists(src), playlistId = playlistId }
end

actions.playlistPlay = function(src, payload)
    local _, netId, vehicleErr = vehicleForSource(src)
    if not netId then return nil, vehicleErr end
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    payload = type(payload) == 'table' and payload or {}
    local playlistId = math.floor(tonumber(payload.playlistId) or 0)
    if not playlistOwned(characterId, playlistId) then return nil, 'Playlist not found.' end
    local tracks = loadPlaylistTracks(playlistId)
    if #tracks == 0 then return nil, 'This playlist is empty.' end
    local mode = payload.mode == 'queue' and 'queue' or 'play'
    local queue = queues[netId] or {}
    local maxQueue = math.max(1, tonumber(Config.QueueLimit) or 20)
    if mode == 'play' then
        queue = {}
        local first = table.remove(tracks, 1)
        local old = radios[netId]
        startEntry(src, netId, first, old and old.volume or payload.volume or Config.DefaultVolume, false)
    end
    local added = 0
    for _, entry in ipairs(tracks) do
        if #queue >= maxQueue then break end
        queue[#queue+1] = entry
        added = added + 1
    end
    queues[netId] = queue
    TriggerClientEvent('nova_carradio:client:queue', -1, netId, queue)
    return { state = statePublic(radios[netId]), queue = queue, playlists = loadPlaylists(src), added = added }
end

actions.playlistTrackPlay = function(src, payload)
    local _, netId, vehicleErr = vehicleForSource(src)
    if not netId then return nil, vehicleErr end
    local characterId = getCharacterId(src)
    if not characterId then return nil, 'Character is not loaded.' end
    payload = type(payload) == 'table' and payload or {}
    local playlistId = math.floor(tonumber(payload.playlistId) or 0)
    local trackId = math.floor(tonumber(payload.trackId) or 0)
    if not playlistOwned(characterId, playlistId) then return nil, 'Playlist not found.' end
    local row = MySQL.single.await('SELECT `id`,`url`,`provider`,`title`,`author`,`artwork` FROM `nova_carradio_playlist_tracks` WHERE `id` = ? AND `playlist_id` = ? LIMIT 1', { trackId, playlistId })
    if not row then return nil, 'Track not found.' end
    local old = radios[netId]
    local state = startEntry(src, netId, row, old and old.volume or payload.volume or Config.DefaultVolume, false)
    return { state = state, queue = queues[netId] or {}, playlists = loadPlaylists(src), entry = row }
end

local function rateAllowed(src)
    local current = GetGameTimer()
    local entry = requestRate[src] or { tokens = 12.0, at = current }
    local elapsed = math.max(0, current - entry.at) / 1000.0
    entry.tokens = math.min(12.0, entry.tokens + elapsed * 6.0)
    entry.at = current
    requestRate[src] = entry
    if entry.tokens < 1.0 then return false end
    entry.tokens = entry.tokens - 1.0
    return true
end


local function registerDeveloperCallbacks()
    local first = NovaCarRadioFramework.registerServerCallback('nova_carradio:getCurrentVehicleRadio', function(src, cb)
        local _, netId = vehicleForSource(src)
        cb(netId and statePublic(radios[netId]) or nil)
    end)
    local second = NovaCarRadioFramework.registerServerCallback('nova_carradio:getVehicleRadioState', function(_, cb, netId)
        cb(statePublic(radios[tonumber(netId)]))
    end)
    return first and second
end

CreateThread(function()
    Wait(1000)
    registerDeveloperCallbacks()
end)

AddEventHandler('onResourceStart', function(name)
    if not NovaCarRadioFramework.isFrameworkResource(name) then return end
    CreateThread(function()
        Wait(500)
        NovaCarRadioFramework.refresh(true)
        registerDeveloperCallbacks()
    end)
end)

RegisterNetEvent('nova_carradio:server:request', function(requestId, actionName, payload)
    local src = source
    if type(requestId) ~= 'string' or #requestId > 96 then return end
    if type(actionName) ~= 'string' or type(actions[actionName]) ~= 'function' then
        TriggerClientEvent('nova_carradio:client:response', src, requestId, nil, 'Invalid car radio request.')
        return
    end
    if not rateAllowed(src) then
        TriggerClientEvent('nova_carradio:client:response', src, requestId, nil, 'Too many radio requests. Wait a moment.')
        return
    end
    local okPack, packed = pcall(msgpack.pack, payload)
    if not okPack or type(packed) ~= 'string' or #packed > (tonumber(Config.MaxRequestPayloadBytes) or 32768) then
        TriggerClientEvent('nova_carradio:client:response', src, requestId, nil, 'Radio request payload is too large.')
        return
    end
    CreateThread(function()
        local ok, data, err = xpcall(function()
            return actions[actionName](src, payload)
        end, debug.traceback)
        if not ok then
            print(('^1[NOVA CARRADIO] %s failed for %d: %s^7'):format(actionName, src, tostring(data)))
            TriggerClientEvent('nova_carradio:client:response', src, requestId, nil, 'Car radio request failed.')
            return
        end
        TriggerClientEvent('nova_carradio:client:response', src, requestId, data, err)
    end)
end)

RegisterNetEvent('nova_carradio:server:requestSnapshot', function()
    local src = source
    local out = {}
    for netId, state in pairs(radios) do out[tostring(netId)] = statePublic(state) end
    TriggerClientEvent('nova_carradio:client:snapshot', src, out)
end)

RegisterNetEvent('nova_carradio:server:ended', function(netId, token)
    local src = source
    netId = tonumber(netId)
    local state = netId and radios[netId] or nil
    if not state or state.token ~= token or not state.playing then return end
    local queue = queues[netId] or {}
    if state.loop then
        state.position = 0
        state.startedAt = now()
        state.token = newToken()
        state.updatedAt = now()
        publish(netId)
        return
    end
    if #queue > 0 then
        local entry = table.remove(queue, 1)
        queues[netId] = queue
        startEntry(src, netId, entry, state.volume, state.loop)
        TriggerClientEvent('nova_carradio:client:queue', -1, netId, queue)
    else
        radios[netId] = nil
        publish(netId)
    end
end)

CreateThread(function()
    while true do
        Wait(30000)
        for netId in pairs(radios) do
            local entity = NetworkGetEntityFromNetworkId(netId)
            if not entity or entity == 0 or not DoesEntityExist(entity) then
                radios[netId] = nil
                queues[netId] = nil
                previousTracks[netId] = nil
                TriggerClientEvent('nova_carradio:client:state', -1, netId, nil)
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    requestRate[source] = nil
end)


AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    NovaCarRadioFramework.removeServerCallback('nova_carradio:getCurrentVehicleRadio')
    NovaCarRadioFramework.removeServerCallback('nova_carradio:getVehicleRadioState')
end)

exports('GetVehicleRadioState', function(netId)
    return statePublic(radios[tonumber(netId)])
end)

exports('StopVehicleRadio', function(netId)
    netId = tonumber(netId)
    if not netId then return false end
    radios[netId] = nil
    publish(netId)
    return true
end)

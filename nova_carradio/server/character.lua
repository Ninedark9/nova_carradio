NovaCarRadioCharacter = NovaCarRadioCharacter or {}

local function normalizeCharacterId(value)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' or #value > 128 then return nil end
    return value
end

local function tryResolver(fn)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn)
    if not ok then return nil end
    return normalizeCharacterId(value)
end

function NovaCarRadioCharacter.resolve(_, deps)
    deps = type(deps) == 'table' and deps or {}
    local resolvers = {
        {'export', deps.exportCharacterId},
        {'function', deps.functionCharacterId},
        {'playerData', deps.playerDataCharacterId},
        {'playerObject', deps.playerObjectCharacterId},
        {'stateBag', deps.stateCharacterId},
    }
    for _, entry in ipairs(resolvers) do
        local id = tryResolver(entry[2])
        if id then return id, entry[1] end
    end
    return nil, nil
end

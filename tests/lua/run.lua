-- Lua test runner for the template. Loads the real resource files against the
-- FiveM stub in harness.lua and asserts on behaviour, not on source text.
--
--   lua5.4 tests/lua/run.lua

local harness = dofile('tests/lua/harness.lua')
local suite = {}

_G.harness = harness

function _G.test(name, fn)
    suite[#suite + 1] = { name = name, fn = fn }
end

local function fail(message, level)
    error(('%s'):format(message), (level or 2) + 1)
end

function _G.assertEq(actual, expected, message)
    if actual ~= expected then
        fail(('%sexpected %s, got %s'):format(message and (message .. ': ') or '', tostring(expected), tostring(actual)))
    end
end

function _G.assertTrue(value, message)
    if value ~= true then fail(('%sexpected true, got %s'):format(message and (message .. ': ') or '', tostring(value))) end
end

function _G.assertFalse(value, message)
    if value ~= false then fail(('%sexpected false, got %s'):format(message and (message .. ': ') or '', tostring(value))) end
end

function _G.assertNil(value, message)
    if value ~= nil then fail(('%sexpected nil, got %s'):format(message and (message .. ': ') or '', tostring(value))) end
end

local function deepEq(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for key, value in pairs(a) do
        if not deepEq(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

function _G.assertDeepEq(actual, expected, message)
    if not deepEq(actual, expected) then
        fail(('%stables differ'):format(message and (message .. ': ') or ''))
    end
end

function _G.assertThrows(fn, message)
    local ok = pcall(fn)
    if ok then fail(('%sexpected an error'):format(message and (message .. ': ') or '')) end
end

local specs = {
    'tests/lua/spec_bridge_server.lua',
    'tests/lua/spec_standalone.lua',
    'tests/lua/spec_storage.lua',
    'tests/lua/spec_repository.lua',
    'tests/lua/spec_access.lua',
    'tests/lua/spec_commands.lua',
    'tests/lua/spec_bridge_client.lua',
    'tests/lua/spec_menu.lua',
    'tests/lua/spec_interactions.lua',
    'tests/lua/spec_firefighter_shared.lua',
    'tests/lua/spec_firefighter_server.lua',
    'tests/lua/spec_firefighter_client.lua',
    'tests/lua/spec_firefighter_database.lua',
    'tests/lua/spec_firefighter_editor.lua',
}

for _, spec in ipairs(specs) do
    local chunk, err = loadfile(spec)
    if not chunk then io.stderr:write(('failed to load %s: %s\n'):format(spec, err)) os.exit(1) end
    chunk()
end

local passed, failures = 0, {}
for _, case in ipairs(suite) do
    harness.reset()
    local ok, err = pcall(case.fn)
    if ok then
        passed = passed + 1
        io.write('.')
    else
        failures[#failures + 1] = { name = case.name, err = err }
        io.write('F')
    end
end
io.write('\n')

for _, failure in ipairs(failures) do
    io.stderr:write(('\nFAIL %s\n  %s\n'):format(failure.name, tostring(failure.err)))
end

io.write(('\n%d passed, %d failed (%d total)\n'):format(passed, #failures, #suite))
os.exit(#failures == 0 and 0 or 1)

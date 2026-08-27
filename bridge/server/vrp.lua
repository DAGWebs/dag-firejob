local Bridge = DAG.Framework

-- vRP forks share almost nothing but a name: vRP1 exposes its API through
-- `Proxy.getInterface`, which needs `@vrp/lib/utils.lua` in the manifest and
-- would make this template hard-depend on vRP. Forks that publish exports are
-- probed here; everything else is deliberately left unimplemented so the
-- bridge reports "unsupported" instead of inventing balances or jobs.
--
-- Teach the bridge about your fork from your own resource:
--
--   DAG.Framework.ExtendAdapter('vrp', {
--       getMoney = function(source, account) ... end,
--       addMoney = function(source, account, amount) ... end,
--   })
local probe

local function userId(source)
    if probe == false then return nil end
    local ok, id = pcall(function() return exports.vrp:getUserId(source) end)
    if not ok then
        if probe == nil then
            probe = false
            Bridge.Print('vRP fork does not export getUserId; extend the vrp adapter with DAG.Framework.ExtendAdapter')
        end
        return nil
    end
    probe = true
    return id
end

Bridge.RegisterAdapter('vrp', {
    getPlayer = userId,
    getIdentifier = function(source)
        local id = userId(source)
        return id and tostring(id) or nil
    end
})

DAG.Commands = DAG.Commands or {}
local Commands = DAG.Commands
local Bridge = DAG.Framework
local suggestions = {}

function Commands.Register(name, handler, options)
    options = options or {}
    assert(type(name) == 'string' and name ~= '', 'Invalid command name')
    assert(type(handler) == 'function', 'Invalid command handler')

    RegisterCommand(name, function(source, args, raw)
        if source == 0 and options.allowConsole == false then return end
        if options.permission and not Bridge.HasPermission(source, options.permission) then
            if source > 0 then Bridge.Notify(source, 'You do not have permission.', 'error') end
            return
        end

        -- A command handler error must not take the command system with it.
        local ok, err = pcall(handler, source, args, raw)
        if not ok then Bridge.Print("command '%s' errored: %s", name, tostring(err)) end
    end, options.restricted == true)

    if options.help then
        suggestions[name] = { help = options.help, arguments = options.arguments or {} }
        TriggerClientEvent('chat:addSuggestion', -1, '/' .. name, options.help, suggestions[name].arguments)
    end
end

function Commands.RemoveSuggestion(name)
    suggestions[name] = nil
    TriggerClientEvent('chat:removeSuggestion', -1, '/' .. name)
end

-- Suggestions are broadcast when a command is registered, which is before
-- anyone has connected. Replaying them per player keeps late joiners in sync.
AddEventHandler('playerJoining', function()
    local playerSource = source
    for name, suggestion in pairs(suggestions) do
        TriggerClientEvent('chat:addSuggestion', playerSource, '/' .. name, suggestion.help, suggestion.arguments)
    end
end)

exports('GetCommands', function() return Commands end)

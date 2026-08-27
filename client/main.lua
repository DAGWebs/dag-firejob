local Bridge = DAG.Framework

RegisterNetEvent(Bridge.Event('client:notify'), function(message, kind, duration)
    Bridge.Notify(message, kind, duration)
end)

RegisterCommand(Bridge.namespace .. ':menu', function()
    local job = Bridge.GetJob()
    DAG.Menu.Register({
        id = Bridge.Event('diagnostics'),
        title = 'Resource diagnostics',
        options = {
            { title = ('Framework: %s'):format(Bridge.Detect()), disabled = true },
            {
                -- GetJob returns nil when the framework cannot report one.
                title = job and ('Framework job: %s (%s)'):format(job.label, job.grade) or 'Framework job: unavailable',
                disabled = true
            },
            { title = ('Menu provider: %s'):format(DAG.Menu.Provider()), disabled = true },
            { title = 'Close', onSelect = function() DAG.Menu.Close() end }
        }
    })
    DAG.Menu.Open(Bridge.Event('diagnostics'))
end, false)

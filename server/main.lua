local Bridge = DAG.Framework

-- Startup capability report. Unsupported adapter methods now return nil rather
-- than a fabricated 0/unemployed, so this line is where you find out that (for
-- example) the active core cannot report jobs before a gate silently denies
-- every player.
CreateThread(function()
    Bridge.AwaitReady(10000)
    Bridge.Print('framework adapter: %s', Bridge.Detect())
    if not Config.ReportCapabilities then return end

    local missing = Bridge.MissingCapabilities()
    if #missing == 0 then return end
    Bridge.Print('unsupported on this framework: %s', table.concat(missing, ', '))
    Bridge.Print('extend it with DAG.Framework.ExtendAdapter(%q, { ... }) if your server needs them', Bridge.Detect())
end)

-- Keep this entrypoint for your resource. The bridge reads framework-owned
-- player state; repositories should only contain data owned by your resource.
Bridge.RegisterCallback(Bridge.Event('getPlayerContext'), function(source, reply)
    reply({
        identifier = Bridge.GetIdentifier(source),
        name = Bridge.GetName(source),
        job = Bridge.GetJob(source),
        framework = Bridge.Detect()
    })
end)

DAG.Commands.Register(Bridge.namespace .. ':framework', function(source)
    local job = source > 0 and Bridge.GetJob(source)
    local message = ('Framework: %s | identifier: %s | job: %s'):format(
        Bridge.Detect(),
        source > 0 and (Bridge.GetIdentifier(source) or 'unknown') or 'console',
        job and ('%s (%s)'):format(job.name, job.grade) or 'unavailable'
    )
    if source == 0 then Bridge.Print(message) else Bridge.Notify(source, message, 'inform') end
end, { help = 'Show the active framework adapter.' })

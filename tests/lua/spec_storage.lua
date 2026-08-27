local function loadStorage(seed)
    if seed then harness.files['data/storage.json'] = seed end
    return harness.loadServer({ adapters = { 'standalone' }, modules = { 'storage' } })
end

test('Get returns a copy, so callers cannot mutate the store', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { stock = { water = 5 } })

    local record = DAG.Storage.Get('shops', 'a')
    record.stock.water = 999
    record.injected = true

    local fresh = DAG.Storage.Get('shops', 'a')
    assertEq(fresh.stock.water, 5)
    assertNil(fresh.injected)
end)

test('Set copies the value it is handed', function()
    loadStorage()
    local input = { stock = { water = 1 } }
    DAG.Storage.Set('shops', 'a', input)
    input.stock.water = 42

    assertEq(DAG.Storage.Get('shops', 'a').stock.water, 1)
end)

test('All returns a deep copy of the collection', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { stock = { water = 5 } })

    local all = DAG.Storage.All('shops')
    all.a.stock.water = 0
    assertEq(DAG.Storage.Get('shops', 'a').stock.water, 5)
end)

test('the deep copy survives a self-referencing table', function()
    loadStorage()
    local record = { name = 'loop' }
    record.self = record

    DAG.Storage.Set('cycles', 'a', record)
    local stored = DAG.Storage.Get('cycles', 'a')
    assertEq(stored.name, 'loop')
    assertEq(stored.self, stored, 'the cycle is preserved, not expanded forever')
end)

test('ids are normalised to strings', function()
    loadStorage()
    DAG.Storage.Set('shops', 1, { name = 'first' })
    assertEq(DAG.Storage.Get('shops', '1').name, 'first')
end)

test('Update merges into the existing record', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner', open = true })
    DAG.Storage.Update('shops', 'a', { open = false })

    local record = DAG.Storage.Get('shops', 'a')
    assertEq(record.name, 'Corner')
    assertFalse(record.open)
end)

test('Update creates a record that does not exist yet', function()
    loadStorage()
    DAG.Storage.Update('shops', 'new', { name = 'Fresh' })
    assertEq(DAG.Storage.Get('shops', 'new').name, 'Fresh')
end)

test('Delete reports whether anything was removed', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner' })
    assertTrue(DAG.Storage.Delete('shops', 'a'))
    assertFalse(DAG.Storage.Delete('shops', 'a'))
    assertNil(DAG.Storage.Get('shops', 'a'))
end)

test('Find returns copies of matching records only', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { city = 'ls' })
    DAG.Storage.Set('shops', 'b', { city = 'pb' })

    local results = DAG.Storage.Find('shops', function(record) return record.city == 'ls' end)
    assertEq(#results, 1)
    assertEq(results[1].city, 'ls')

    results[1].city = 'mutated'
    assertEq(DAG.Storage.Get('shops', 'a').city, 'ls')
end)

test('record events carry the collection, id, and value', function()
    loadStorage()
    local updated, deleted
    AddEventHandler(DAG.Framework.Event('recordUpdated'), function(name, id, value)
        updated = { name = name, id = id, value = value }
    end)
    AddEventHandler(DAG.Framework.Event('recordDeleted'), function(name, id)
        deleted = { name = name, id = id }
    end)

    DAG.Storage.Set('shops', 7, { name = 'Corner' })
    DAG.Storage.Delete('shops', 7)

    assertEq(updated.name, 'shops')
    assertEq(updated.id, '7')
    assertEq(updated.value.name, 'Corner')
    assertEq(deleted.id, '7')
end)

test('a valid seed file is loaded on start', function()
    loadStorage('{"shops":{"a":{"name":"Seeded"}}}')
    assertEq(DAG.Storage.Get('shops', 'a').name, 'Seeded')
end)

test('an invalid seed file is reported and does not abort the resource', function()
    loadStorage('{not json')
    assertTrue(harness.outputContains('ignoring invalid storage JSON'))
    assertDeepEq(DAG.Storage.All('shops'), {})
end)

test('Save writes only when the store is dirty', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner' })
    assertTrue(DAG.Storage.Save())
    assertTrue(harness.savedFiles['data/storage.json'] ~= nil)

    harness.savedFiles['data/storage.json'] = nil
    assertTrue(DAG.Storage.Save(), 'a clean store still reports success')
    assertNil(harness.savedFiles['data/storage.json'], 'but performs no write')
end)

test('Save writes decodable JSON', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner', stock = { water = 2 } })
    DAG.Storage.Save()

    local decoded = json.decode(harness.savedFiles['data/storage.json'])
    assertEq(decoded.shops.a.stock.water, 2)
end)

-- A record holding an unserialisable value used to throw inside the save
-- thread, which silently killed every future write for the session.
test('an unserialisable record fails the write without killing the store', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner' })
    DAG.Storage.Save()
    DAG.Storage.Set('shops', 'b', { onUse = print })

    assertFalse(DAG.Storage.Save())
    assertTrue(harness.outputContains('failed to encode storage'))
    assertEq(DAG.Storage.Get('shops', 'a').name, 'Corner', 'in-memory data survives')
end)

test('the save interval is clamped to a floor', function()
    harness.loadConfig()
    Config.Storage.saveInterval = 5
    harness.load('bridge/shared.lua')
    harness.load('bridge/server.lua')
    harness.load('bridge/server/standalone.lua')
    harness.load('modules/storage/server.lua')

    assertTrue(harness.outputContains('raised to 1000ms'))
end)

test('the periodic save thread flushes pending writes', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner' })
    harness.runThread(harness.threads[#harness.threads], 1)
    assertTrue(harness.savedFiles['data/storage.json'] ~= nil)
end)

test('stopping the resource flushes to disk', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner' })
    TriggerEvent('onResourceStop', 'dag-template')
    assertTrue(harness.savedFiles['data/storage.json'] ~= nil)
end)

test('stopping a different resource does not flush', function()
    loadStorage()
    DAG.Storage.Set('shops', 'a', { name = 'Corner' })
    TriggerEvent('onResourceStop', 'some-other-resource')
    assertNil(harness.savedFiles['data/storage.json'])
end)

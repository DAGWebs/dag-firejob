local function loadRepository()
    return harness.loadServer({
        adapters = { 'standalone' },
        modules = { 'storage', 'access', 'repository' }
    })
end

test('a repository round-trips records through storage', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops')

    shops.save('a', { name = 'Corner' })
    assertEq(shops.get('a').name, 'Corner')
    assertEq(shops.count(), 1)

    shops.delete('a')
    assertNil(shops.get('a'))
    assertEq(shops.count(), 0)
end)

-- Validation is usually driven by client input, so a rejected record returns
-- an error instead of unwinding the event handler that produced it.
test('validation failures return nil and a message rather than throwing', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops', {
        validate = function(record)
            return type(record.name) == 'string', 'A shop requires a name'
        end
    })

    local saved, message = shops.save('a', { name = 42 })
    assertNil(saved)
    assertEq(message, 'A shop requires a name')
    assertNil(shops.get('a'), 'nothing was written')

    assertEq(shops.save('a', { name = 'Corner' }).name, 'Corner')
end)

test('validation receives the merged record on update', function()
    loadRepository()
    local seen
    local shops = DAG.Repository.Create('shops', {
        validate = function(record, operation)
            seen = { record = record, operation = operation }
            return true
        end
    })

    shops.save('a', { name = 'Corner', open = true })
    shops.update('a', { open = false })

    assertEq(seen.operation, 'update')
    assertEq(seen.record.name, 'Corner', 'existing fields are present')
    assertFalse(seen.record.open, 'alongside the change')
end)

test('a rejected update leaves the stored record untouched', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops', {
        validate = function(record) return type(record.name) == 'string', 'name must be a string' end
    })

    shops.save('a', { name = 'Corner', open = true })
    local updated, message = shops.update('a', { name = 42 })
    assertNil(updated)
    assertEq(message, 'name must be a string')
    assertEq(shops.get('a').name, 'Corner')
    assertTrue(shops.get('a').open)
end)

test('non-table input is rejected without reaching storage', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops')
    assertNil(shops.save('a', 'not a table'))
    assertNil(shops.update('a', 'not a table'))
    assertEq(shops.count(), 0)
end)

test('find filters within the collection', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops')
    shops.save('a', { city = 'ls' })
    shops.save('b', { city = 'pb' })

    local matches = shops.find(function(record) return record.city == 'pb' end)
    assertEq(#matches, 1)
    assertEq(matches[1].city, 'pb')
end)

test('can() denies a record that does not exist', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops')
    assertFalse(shops.can(1, 'missing', 'read'))
end)

test('can() defers to the access policy stored on the record', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops')
    harness.identifiers[1] = 'license:owner'
    harness.identifiers[2] = 'license:other'

    shops.save('a', { access = { owner = 'license:owner' } })
    assertTrue(shops.can(1, 'a', 'edit'))
    assertFalse(shops.can(2, 'a', 'edit'))
end)

test('a custom authorize hook overrides the default policy', function()
    loadRepository()
    local shops = DAG.Repository.Create('shops', {
        authorize = function(_, record, action) return record.city == 'ls' and action == 'read' end
    })

    shops.save('a', { city = 'ls', access = { public = true } })
    assertTrue(shops.can(2, 'a', 'read'))
    assertFalse(shops.can(2, 'a', 'write'), 'the hook wins over the public policy')
end)

test('a collection name is required', function()
    loadRepository()
    assertThrows(function() DAG.Repository.Create('') end)
    assertThrows(function() DAG.Repository.Create(nil) end)
end)

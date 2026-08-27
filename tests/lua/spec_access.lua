local function loadAccess()
    return harness.loadServer({ adapters = { 'standalone' }, modules = { 'access' } })
end

test('the console is always allowed', function()
    loadAccess()
    assertTrue(DAG.Access.Allowed(0, {}, 'read'))
end)

test('a public policy allows anyone', function()
    loadAccess()
    assertTrue(DAG.Access.Allowed(1, { public = true }, 'read'))
end)

test('an ACE policy defers to the server ACL', function()
    loadAccess()
    harness.aceAllowed[1] = { ['shop.manage'] = true }
    assertTrue(DAG.Access.Allowed(1, { ace = 'shop.manage' }, 'edit'))
    assertFalse(DAG.Access.Allowed(2, { ace = 'shop.manage' }, 'edit'))
end)

test('the owner identifier is allowed', function()
    loadAccess()
    harness.identifiers[1] = 'license:owner'
    assertTrue(DAG.Access.Allowed(1, { owner = 'license:owner' }, 'edit'))
    assertFalse(DAG.Access.Allowed(2, { owner = 'license:owner' }, 'edit'))
end)

test('members can be granted all or specific actions', function()
    loadAccess()
    harness.identifiers[1] = 'license:a'
    harness.identifiers[2] = 'license:b'
    harness.identifiers[3] = 'license:c'

    local policy = {
        members = {
            ['license:a'] = true,
            ['license:b'] = { read = true },
            ['license:c'] = { ['*'] = true }
        }
    }

    assertTrue(DAG.Access.Allowed(1, policy, 'delete'))
    assertTrue(DAG.Access.Allowed(2, policy, 'read'))
    assertFalse(DAG.Access.Allowed(2, policy, 'delete'))
    assertTrue(DAG.Access.Allowed(3, policy, 'delete'))
end)

test('a job policy requires the minimum grade', function()
    loadAccess()
    DAG.Framework.RegisterAdapter('standalone', {
        getJob = function() return { name = 'police', grade = 2 } end
    })

    assertTrue(DAG.Access.Allowed(1, { jobs = { police = 2 } }, 'read'))
    assertFalse(DAG.Access.Allowed(1, { jobs = { police = 3 } }, 'read'))
    assertFalse(DAG.Access.Allowed(1, { jobs = { ambulance = 0 } }, 'read'))
end)

-- Regression: GetJob now returns nil where a framework cannot report jobs.
-- An unknown job must never be treated as a match.
test('an unknown job is a denial, not a match', function()
    loadAccess()
    DAG.Framework.RegisterAdapter('standalone', {})

    assertFalse(DAG.Access.Allowed(1, { jobs = { unemployed = 0 } }, 'read'))
    assertFalse(DAG.Access.Allowed(1, { jobs = { police = 0 } }, 'read'))
end)

test('a missing identifier does not match an owner or member entry', function()
    loadAccess()
    DAG.Framework.RegisterAdapter('standalone', {})
    harness.identifiers[1] = nil

    assertFalse(DAG.Access.Allowed(1, { owner = nil }, 'read'))
    assertFalse(DAG.Access.Allowed(1, { members = {} }, 'read'))
end)

test('an empty policy denies everyone but the console', function()
    loadAccess()
    assertFalse(DAG.Access.Allowed(1, nil, 'read'))
    assertFalse(DAG.Access.Allowed(1, {}, 'read'))
end)

test('Require notifies the player it denies', function()
    loadAccess()
    assertFalse(DAG.Access.Require(1, {}, 'read'))
    assertEq(harness.clientEvents[1].event, DAG.Framework.Event('client:notify'))
    assertEq(harness.clientEvents[1].args[1], 'You do not have access to this.')
end)

test('Require stays quiet when access is granted', function()
    loadAccess()
    assertTrue(DAG.Access.Require(1, { public = true }, 'read'))
    assertEq(#harness.clientEvents, 0)
end)

-- Shared firefighter logic: ranks, certifications, suppression arithmetic, and
-- the formatting both sides rely on.

local function loadShared()
    return harness.loadServer({
        adapters = { 'standalone' },
        shared = { 'modules/firefighter/config.lua', 'modules/firefighter/shared.lua' }
    })
end

local function shared()
    loadShared()
    return DAG.Fire.Shared
end

test('the job declares itself enabled with a full catalogue', function()
    local Shared = shared()
    assertTrue(Shared.Enabled())
    assertTrue(#Shared.Stations() > 0)
    assertTrue(#Shared.CallTypes() > 0)
    assertEq(Shared.CallType('structure').label, 'Structure fire')
    assertNil(Shared.CallType('nope'))
end)

test('coords accept a vector3 or a plain table and measure the same distance', function()
    local Shared = shared()
    assertEq(Shared.Distance(vector3(0, 0, 0), { x = 3, y = 4, z = 0 }), 5.0)
    assertEq(Shared.Distance({ 0, 0, 0 }, { x = 0, y = 0, z = 2 }), 2.0)
    assertEq(Shared.Distance(nil, { x = 1, y = 1, z = 1 }), math.huge)
end)

test('rank is the highest one the XP total has reached', function()
    local Shared = shared()
    assertEq(Shared.RankFor(0).id, 'probationary')
    assertEq(Shared.RankFor(749).id, 'probationary')
    assertEq(Shared.RankFor(750).id, 'firefighter')
    assertEq(Shared.RankFor(999999).id, 'chief')
end)

test('the next rank reports what is still owed', function()
    local Shared = shared()
    local rank, remaining = Shared.NextRank(700)
    assertEq(rank.id, 'firefighter')
    assertEq(remaining, 50)
    assertNil(Shared.NextRank(999999))
end)

test('certifications accumulate from every rank passed, not just the current one', function()
    local Shared = shared()
    local held = Shared.HeldCertifications({ xp = 6000, certifications = {} })
    assertTrue(held.engine, 'granted at firefighter')
    assertTrue(held.ladder, 'granted at engineer')
    assertTrue(held.rescue, 'granted at lieutenant')
    assertNil(held.hazmat, 'captain has not been reached')
end)

test('an officer sign-off grants a certification the rank has not reached', function()
    local Shared = shared()
    local profile = { xp = 0, certifications = { 'hazmat' } }
    assertTrue(Shared.HasCertification(profile, 'hazmat'))
    assertFalse(Shared.HasCertification(profile, 'command'))
    assertTrue(Shared.HasCertification(profile, nil), 'nothing required is always held')
end)

test('pay multiplier follows the rank', function()
    local Shared = shared()
    assertEq(Shared.PayMultiplier(0), 0.85)
    assertEq(Shared.PayMultiplier(25000), 1.75)
end)

test('suppression converts litres into intensity through the agent multiplier', function()
    local Shared = shared()
    -- litresPerPoint is 2.2 and the hose multiplier is 1.0.
    local points, used = Shared.Suppression(22, 'hose', 100)
    assertEq(points, 10.0)
    assertEq(used, 22.0)

    -- The extinguisher moves the same water at 55% effect.
    local weak = Shared.Suppression(22, 'extinguisher', 100)
    assertEq(weak, 5.5)
end)

-- Overshooting a nearly-out fire must not bill the whole burst, or a tank
-- empties itself on the last point of a node.
test('suppression only bills the water that had something left to put out', function()
    local Shared = shared()
    local points, used = Shared.Suppression(90, 'hose', 5)
    assertEq(points, 5.0)
    assertEq(used, 11.0, '5 points at 2.2 litres each')
end)

test('an unknown agent suppresses nothing', function()
    local Shared = shared()
    local points, used = Shared.Suppression(50, 'thoughts', 100)
    assertEq(points, 0)
    assertEq(used, 0)
end)

test('severity averages node intensity and labels it', function()
    local Shared = shared()
    assertEq(Shared.Severity({ fires = {} }), 0)
    assertEq(Shared.Severity({ fires = { a = { intensity = 100 }, b = { intensity = 0 } } }), 0.5)
    assertEq(Shared.SeverityLabel(0), 'Under control')
    assertEq(Shared.SeverityLabel(0.9), 'Fully involved')
end)

test('formatting is stable for ids, money, and durations', function()
    local Shared = shared()
    assertEq(Shared.FormatCallId(42), 'FD-0042')
    assertEq(Shared.FormatMoney(1234567), '$1,234,567')
    assertEq(Shared.FormatMoney(-250), '-$250')
    assertEq(Shared.FormatDuration(45000), '45s')
    assertEq(Shared.FormatDuration(125000), '2m 05s')
end)

-- Storage round-trips through JSON, so a profile can come back missing
-- anything that was empty, or carrying anything an admin typed into the file.
test('a stored profile is normalized back into a complete record', function()
    local Shared = shared()
    local profile = Shared.NormalizeProfile({
        xp = -50,
        certifications = { 'hazmat', 'not-a-certification' },
        stats = { calls = 7 }
    }, 'license:abc', 'Dana Reyes')

    assertEq(profile.identifier, 'license:abc')
    assertEq(profile.name, 'Dana Reyes')
    assertEq(profile.xp, 0, 'negative XP is clamped')
    assertEq(#profile.certifications, 1, 'unknown certifications are dropped')
    assertEq(profile.stats.calls, 7)
    assertEq(profile.stats.victimsRescued, 0, 'missing counters are restored')
end)

test('a missing record still produces a usable profile', function()
    local Shared = shared()
    local profile = Shared.NormalizeProfile(nil, 'license:abc', 'Dana Reyes')
    assertEq(profile.xp, 0)
    assertEq(profile.stats.calls, 0)
end)

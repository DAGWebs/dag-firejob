-- Pay, experience, training, and the career record behind them.
--
-- The framework still owns the money: this module decides the amount and hands
-- it to the bridge. Everything it keeps for itself (XP, sign-offs, lifetime
-- stats) is resource-owned data in the repository.

local Bridge = DAG.Framework
local Fire = DAG.Fire
local Shared = Fire.Shared
local State = Fire.State
local Progression = {}
Fire.Progression = Progression

local function paySettings()
    return Shared.Settings().pay or {}
end

-- What the call is worth before it is divided up.
function Progression.CallValue(call)
    local pay = paySettings()
    local total = tonumber(call.payout) or 0

    total = total + (tonumber(pay.perFire) or 0) * (call.extinguished or 0)
    total = total + (tonumber(pay.perVictim) or 0) * ((call.rescued or 0) + (call.transported or 0))
    total = total + (tonumber(pay.perHazard) or 0) * (call.contained or 0)

    local window = tonumber((Shared.Settings().dispatch or {}).responseWindow) or 180000
    if call.responseTime and call.responseTime <= window then
        total = total + (tonumber(pay.responseBonus) or 0)
    end

    local lost = 0
    for _, victim in pairs(call.victims or {}) do
        if victim.state == Fire.VictimState.deceased then lost = lost + 1 end
    end
    if lost == 0 and next(call.victims or {}) ~= nil then
        total = total * (tonumber(pay.cleanSceneBonus) or 1.0)
    end

    return math.floor(total + 0.5), lost
end

-- Shares are part flat and part earned. `minimumShare` of an equal split is
-- guaranteed for turning out at all; the rest follows the water each
-- firefighter actually put on the fire, so the crew that worked it is paid for
-- working it without leaving the newest member on nothing.
function Progression.Shares(call, attendees)
    local pay = paySettings()
    local count = #attendees
    if count == 0 then return {} end

    local contribution, total = call.contribution or {}, 0
    for _, responder in ipairs(attendees) do
        total = total + (contribution[responder.identifier] or 0)
    end

    local shares = {}
    if pay.split == false then
        for _, responder in ipairs(attendees) do shares[responder.identifier] = 1.0 end
        return shares
    end

    local guaranteed = Shared.Clamp(tonumber(pay.minimumShare) or 0.35, 0, 1) / count
    local remaining = 1.0 - guaranteed * count

    for _, responder in ipairs(attendees) do
        local weight = total > 0 and ((contribution[responder.identifier] or 0) / total) or (1 / count)
        shares[responder.identifier] = guaranteed + remaining * weight
    end
    return shares
end

local function attendeesFor(call)
    local list = {}
    for identifier, responder in pairs(call.responders or {}) do
        -- Signing on to a call from across the map is not the same as working
        -- it: only firefighters who actually arrived are paid.
        if responder.arrivedAt then
            list[#list + 1] = {
                identifier = identifier,
                source = responder.source,
                name = responder.name
            }
        end
    end
    table.sort(list, function(a, b) return a.identifier < b.identifier end)
    return list
end

local function applyStats(profile, call, share)
    local stats = profile.stats
    stats.calls = (stats.calls or 0) + 1
    stats.firesExtinguished = (stats.firesExtinguished or 0) + math.floor((call.extinguished or 0) * share + 0.5)
    -- Patients, not patient handling steps: a transport pays on top of the
    -- treatment, but the same person is one life on the career record.
    stats.victimsRescued = (stats.victimsRescued or 0) + math.floor((call.rescued or 0) * share + 0.5)
    stats.hazardsContained = (stats.hazardsContained or 0) + math.floor((call.contained or 0) * share + 0.5)
    stats.litresUsed = math.floor((stats.litresUsed or 0) + ((call.contribution or {})[profile.identifier] or 0))

    if call.responseTime and (not stats.fastestResponse or call.responseTime < stats.fastestResponse) then
        stats.fastestResponse = call.responseTime
    end
end

-- Called once, by Dispatch.Resolve. Returns what each attendee was awarded so
-- the caller can log or display it.
function Progression.Award(call, reason)
    local attendees = attendeesFor(call)
    if #attendees == 0 then return {} end

    local value, lost = Progression.CallValue(call)
    local shares = Progression.Shares(call, attendees)
    local account = paySettings().account or 'bank'
    local awards = {}

    for _, attendee in ipairs(attendees) do
        local profile = State.ProfileFor(attendee.identifier, attendee.name)
        if profile then
            local share = shares[attendee.identifier] or 0
            local beforeRank = select(2, Shared.RankFor(profile.xp))
            local multiplier = Shared.PayMultiplier(profile.xp)
            local amount = math.floor(value * share * multiplier + 0.5)
            local xp = math.floor((tonumber(call.xp) or 0) * math.min(1.5, share * #attendees) + 0.5)

            profile.xp = profile.xp + xp
            applyStats(profile, call, share)

            -- Money is only paid to a player who is still connected; the XP and
            -- the record are kept either way, so a crash on the way back to the
            -- station does not erase the call.
            local paid = false
            if amount > 0 and State.IsOnDuty(attendee.source) then
                paid = Bridge.AddMoney(attendee.source, account, amount, ('firefighter:%s'):format(call.id))
                if paid then profile.stats.earnings = (profile.stats.earnings or 0) + amount end
            end

            State.SaveProfile(profile)

            local afterRank, afterIndex = Shared.RankFor(profile.xp)
            if afterIndex > beforeRank and afterRank then
                Fire.Dispatch.Radio(('%s promoted to %s'):format(profile.name, afterRank.label), 'success')
                Bridge.Notify(attendee.source, ('Promoted to %s.'):format(afterRank.label), 'success', 8000)
            end

            if State.IsOnDuty(attendee.source) then
                Bridge.Notify(attendee.source, ('%s closed: %s and %d XP.'):format(
                    call.id,
                    paid and Shared.FormatMoney(amount) or 'no pay (offline)',
                    xp
                ), lost > 0 and 'inform' or 'success', 8000)
                TriggerClientEvent(Bridge.Event('fire:award'), attendee.source, {
                    callId = call.id,
                    amount = paid and amount or 0,
                    xp = xp,
                    reason = reason,
                    rank = Shared.RankLabel(profile.xp)
                })
            end

            awards[#awards + 1] = {
                identifier = attendee.identifier,
                amount = paid and amount or 0,
                xp = xp,
                share = Shared.Round(share, 3)
            }
        end
    end

    return awards
end

-- Training -----------------------------------------------------------------

function Progression.GrantCertification(identifier, certification)
    if not Shared.Certification(certification) then return false, 'unknown_certification' end

    local profile = State.ProfileFor(identifier)
    if not profile then return false, 'unknown_firefighter' end
    if Shared.HasCertification(profile, certification) then return false, 'already_held' end

    profile.certifications[#profile.certifications + 1] = certification
    State.SaveProfile(profile)
    return true, nil, profile
end

function Progression.RevokeCertification(identifier, certification)
    local profile = State.ProfileFor(identifier)
    if not profile then return false, 'unknown_firefighter' end

    local kept, removed = {}, false
    for _, id in ipairs(profile.certifications) do
        if id == certification then removed = true else kept[#kept + 1] = id end
    end
    if not removed then return false, 'not_signed_off' end

    profile.certifications = kept
    State.SaveProfile(profile)
    return true, nil, profile
end

function Progression.AwardXp(identifier, amount)
    local points = tonumber(amount)
    if not points or points ~= points then return false, 'invalid_amount' end

    local profile = State.ProfileFor(identifier)
    if not profile then return false, 'unknown_firefighter' end

    profile.xp = math.max(0, profile.xp + points)
    State.SaveProfile(profile)
    return true, nil, profile
end

function Progression.Leaderboard(limit)
    local list = {}
    for identifier, record in pairs(State.profiles.all()) do
        local profile = Shared.NormalizeProfile(record, identifier, record.name)
        list[#list + 1] = {
            identifier = identifier,
            name = profile.name or 'Unknown',
            xp = profile.xp,
            rank = Shared.RankLabel(profile.xp),
            calls = profile.stats.calls or 0,
            rescues = profile.stats.victimsRescued or 0
        }
    end

    table.sort(list, function(a, b)
        if a.xp ~= b.xp then return a.xp > b.xp end
        return a.name < b.name
    end)

    local capped = {}
    for index = 1, math.min(#list, tonumber(limit) or 10) do capped[index] = list[index] end
    return capped
end

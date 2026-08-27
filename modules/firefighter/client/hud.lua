-- On-duty status panel: air, tank, the call you are on, and what is left to do
-- on it. Drawn with natives rather than NUI so it cannot collide with the
-- bundled menu interface, and it can be turned off entirely from config.

local Fire = DAG.Fire
local Shared = Fire.Shared
local Client = Fire.Client
local Rescue = Fire.Rescue
local Hud = {}
Fire.Hud = Hud

local function hudSettings()
    return Shared.Settings().hud or {}
end

local function text(content, x, y, scale, alpha)
    SetTextFont(4)
    SetTextScale(scale or 0.32, scale or 0.32)
    SetTextColour(235, 238, 244, alpha or 220)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(content)
    EndTextCommandDisplayText(x, y)
end

local function bar(x, y, width, fraction, r, g, b)
    DrawRect(x + width / 2, y + 0.006, width, 0.008, 20, 24, 32, 190)
    local filled = width * Shared.Clamp(fraction, 0, 1)
    if filled > 0 then
        DrawRect(x + filled / 2, y + 0.006, filled, 0.008, r, g, b, 230)
    end
end

-- The one line that says what still has to happen before the call closes.
function Hud.Objectives(call)
    if not call then return nil end

    local burning, trapped, hazards = 0, 0, 0
    for _, node in pairs(call.fires or {}) do
        if (node.intensity or 0) > 0 then burning = burning + 1 end
    end
    for _, victim in pairs(call.victims or {}) do
        if victim.state == Fire.VictimState.trapped or victim.state == Fire.VictimState.freed then
            trapped = trapped + 1
        end
    end
    for _, hazard in pairs(call.hazards or {}) do
        if not hazard.contained then hazards = hazards + 1 end
    end

    local parts = {}
    if burning > 0 then parts[#parts + 1] = ('%d seat%s of fire'):format(burning, burning == 1 and '' or 's') end
    if trapped > 0 then parts[#parts + 1] = ('%d patient%s'):format(trapped, trapped == 1 and '' or 's') end
    if hazards > 0 then parts[#parts + 1] = ('%d release%s'):format(hazards, hazards == 1 and '' or 's') end
    if #parts == 0 then return 'Scene clear - overhaul and close the call' end
    return table.concat(parts, ', ')
end

function Hud.Draw()
    local settings = hudSettings()
    if settings.enabled == false or not Client.OnDuty() then return false end

    local x, y = tonumber(settings.x) or 0.015, tonumber(settings.y) or 0.72
    local scba = Shared.Settings().scba or {}
    local water = Shared.Settings().water or {}
    local unit = Client.Unit()
    local call = Client.Assigned()
    local row = y

    local department = Shared.Department(Client.Department())
    text(('~b~%s'):format(department and department.short or 'FD'), x, row, 0.36)
    row = row + 0.026

    local air = Client.Air() / math.max(1, tonumber(scba.capacity) or 1500)
    text(('Air  %d%%'):format(math.floor(air * 100)), x, row, 0.3)
    bar(x + 0.055, row + 0.004, 0.07, air, air < 0.2 and 220 or 90, air < 0.2 and 70 or 190, 110)
    row = row + 0.022

    local charge = Client.Extinguisher() / math.max(1, tonumber(water.extinguisherCapacity) or 220)
    text(('Ext  %d%%'):format(math.floor(charge * 100)), x, row, 0.3)
    bar(x + 0.055, row + 0.004, 0.07, charge, 200, 170, 70)
    row = row + 0.022

    if unit and (unit.capacity or 0) > 0 then
        local tank = (unit.water or 0) / unit.capacity
        text(('Tank %d%%'):format(math.floor(tank * 100)), x, row, 0.3)
        bar(x + 0.055, row + 0.004, 0.07, tank, 80, 150, 235)
        row = row + 0.022
    end

    local agent = Fire.Suppression and Fire.Suppression.Agent()
    if agent then
        local line = ''
        if Fire.Hose and Fire.Hose.Deployed() then
            local stretch = Fire.Hose.Stretch()
            line = stretch >= 1.0 and '  ~r~LINE STRETCHED' or ('  line %d%%'):format(math.floor(stretch * 100))
        end
        text(('~y~%s in hand%s'):format(agent, line), x, row, 0.28)
        row = row + 0.022
    end

    local course = Fire.Academy and Fire.Academy.Course()
    if course then
        local progress = Fire.Academy.Progress()
        text(('~g~Academy: %s (%s)'):format(course.label or course.id, course.phase), x, row, 0.28)
        row = row + 0.02
        if progress then
            bar(x + 0.055, row + 0.004, 0.09, progress, 120, 200, 120)
            row = row + 0.018
        end
    end

    if call then
        text(('~o~%s  %s'):format(call.id, call.label), x, row, 0.3)
        row = row + 0.02
        text(('~s~%s'):format(call.location or ''), x, row, 0.27, 170)
        row = row + 0.02
        text(('~s~%s'):format(Hud.Objectives(call) or ''), x, row, 0.27, 170)
        row = row + 0.022
    end

    if Fire.Crew then
        local remaining = Fire.Crew.ParRemaining()
        if remaining then
            text(('~r~PAR CHECK  %ds'):format(math.ceil(remaining / 1000)), x, row, 0.32)
            row = row + 0.022
        elseif Fire.Crew.Interior() then
            text('~o~INTERIOR', x, row, 0.28)
            row = row + 0.02
        end
    end

    local progress, kind = Rescue.ActionProgress()
    if progress then
        text(('%s...'):format(kind), x, row, 0.3)
        bar(x + 0.055, row + 0.004, 0.09, progress, 235, 200, 90)
    end

    return true
end

CreateThread(function()
    while true do
        local drawn = Hud.Draw()
        Wait(drawn and 0 or 500)
    end
end)

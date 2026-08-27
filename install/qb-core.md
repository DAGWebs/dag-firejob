# QBCore / QBus

QBCore reads job definitions from `qb-core/shared/jobs.lua`, not from the
database. Add the three departments there.

## Jobs

```lua
-- qb-core/shared/jobs.lua
['lsfd'] = {
    label = 'Los Santos Fire Department',
    defaultDuty = false,
    offDutyPay = false,
    grades = {
        ['0'] = { name = 'Probationary', payment = 500 },
        ['1'] = { name = 'Firefighter', payment = 750 },
        ['2'] = { name = 'Engineer', payment = 900 },
        ['3'] = { name = 'Lieutenant', payment = 1100 },
        ['4'] = { name = 'Captain', payment = 1400 },
        ['5'] = { name = 'Battalion Chief', payment = 1800, isboss = true },
    },
},
['safd'] = {
    label = 'San Andreas County Fire',
    defaultDuty = false,
    offDutyPay = false,
    grades = {
        ['0'] = { name = 'Probationary', payment = 500 },
        ['1'] = { name = 'Firefighter', payment = 750 },
        ['2'] = { name = 'Engineer', payment = 900 },
        ['3'] = { name = 'Lieutenant', payment = 1100 },
        ['4'] = { name = 'Captain', payment = 1400 },
        ['5'] = { name = 'Battalion Chief', payment = 1800, isboss = true },
    },
},
['bcfd'] = {
    label = 'Blaine County Fire and Rescue',
    defaultDuty = false,
    offDutyPay = false,
    grades = {
        ['0'] = { name = 'Probationary', payment = 500 },
        ['1'] = { name = 'Firefighter', payment = 750 },
        ['2'] = { name = 'Engineer', payment = 900 },
        ['3'] = { name = 'Lieutenant', payment = 1100 },
        ['4'] = { name = 'Captain', payment = 1400 },
        ['5'] = { name = 'Battalion Chief', payment = 1800, isboss = true },
    },
},
```

The grade numbers are what `Config.Firefighter.ranks[].grade` sets on a
promotion. Renaming a department means changing `departments[].job` in
`modules/firefighter/config.lua` to match.

## Items

Skip this if you run `ox_inventory`; use [ox_inventory.md](ox_inventory.md)
instead.

```lua
-- qb-core/shared/items.lua
['fire_extinguisher'] = { name = 'fire_extinguisher', label = 'Fire extinguisher', weight = 4000, type = 'item', image = 'fire_extinguisher.png', unique = false, useable = true, shouldClose = true, description = 'Portable dry powder extinguisher.' },
['fire_hose']         = { name = 'fire_hose',         label = 'Hose line',          weight = 6000, type = 'item', image = 'fire_hose.png',         unique = false, useable = true, shouldClose = true, description = 'Attack line for a pump.' },
['scba_tank']         = { name = 'scba_tank',         label = 'SCBA cylinder',      weight = 7000, type = 'item', image = 'scba_tank.png',         unique = false, useable = true, shouldClose = true, description = 'Breathing air for interior work.' },
['jaws_of_life']      = { name = 'jaws_of_life',      label = 'Jaws of life',       weight = 9000, type = 'item', image = 'jaws_of_life.png',      unique = false, useable = false, shouldClose = true, description = 'Hydraulic spreader and cutter.' },
['halligan_bar']      = { name = 'halligan_bar',      label = 'Halligan bar',       weight = 3000, type = 'item', image = 'halligan_bar.png',      unique = false, useable = false, shouldClose = true, description = 'Forcible entry tool.' },
['fd_medbag']         = { name = 'fd_medbag',         label = 'Medical bag',        weight = 5000, type = 'item', image = 'fd_medbag.png',         unique = false, useable = false, shouldClose = true, description = 'Patient assessment and treatment kit.' },
['thermal_camera']    = { name = 'thermal_camera',    label = 'Thermal camera',     weight = 2000, type = 'item', image = 'thermal_camera.png',    unique = false, useable = true, shouldClose = true, description = 'Sees through smoke.' },
['hazmat_kit']        = { name = 'hazmat_kit',        label = 'Hazmat kit',         weight = 8000, type = 'item', image = 'hazmat_kit.png',        unique = false, useable = false, shouldClose = true, description = 'Absorbent and containment gear.' },
```

Item images are your own to supply; the job never reads them.

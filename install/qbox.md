# Qbox

Qbox keeps jobs in `qbx_core/shared/jobs.lua` and always uses `ox_inventory`
for items, so the items go in [ox_inventory.md](ox_inventory.md).

## Jobs

```lua
-- qbx_core/shared/jobs.lua
lsfd = {
    label = 'Los Santos Fire Department',
    defaultDuty = false,
    offDutyPay = false,
    grades = {
        [0] = { name = 'Probationary', payment = 500 },
        [1] = { name = 'Firefighter', payment = 750 },
        [2] = { name = 'Engineer', payment = 900 },
        [3] = { name = 'Lieutenant', payment = 1100 },
        [4] = { name = 'Captain', payment = 1400 },
        [5] = { name = 'Battalion Chief', payment = 1800, isboss = true },
    },
},
safd = {
    label = 'San Andreas County Fire',
    defaultDuty = false,
    offDutyPay = false,
    grades = {
        [0] = { name = 'Probationary', payment = 500 },
        [1] = { name = 'Firefighter', payment = 750 },
        [2] = { name = 'Engineer', payment = 900 },
        [3] = { name = 'Lieutenant', payment = 1100 },
        [4] = { name = 'Captain', payment = 1400 },
        [5] = { name = 'Battalion Chief', payment = 1800, isboss = true },
    },
},
bcfd = {
    label = 'Blaine County Fire and Rescue',
    defaultDuty = false,
    offDutyPay = false,
    grades = {
        [0] = { name = 'Probationary', payment = 500 },
        [1] = { name = 'Firefighter', payment = 750 },
        [2] = { name = 'Engineer', payment = 900 },
        [3] = { name = 'Lieutenant', payment = 1100 },
        [4] = { name = 'Captain', payment = 1400 },
        [5] = { name = 'Battalion Chief', payment = 1800, isboss = true },
    },
},
```

Qbox's own duty flag is set through the bridge when a firefighter clocks on, so
`defaultDuty = false` is correct: the station duty point is what puts them on.

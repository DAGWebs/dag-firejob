# ox_inventory

Use this on any framework running `ox_inventory` — the bridge routes item calls
straight to it, whatever the player framework is.

```lua
-- ox_inventory/data/items.lua
['fire_extinguisher'] = {
    label = 'Fire extinguisher',
    weight = 4000,
    stack = false,
    close = true,
    description = 'Portable dry powder extinguisher.'
},

['fire_hose'] = {
    label = 'Hose line',
    weight = 6000,
    stack = false,
    close = true,
    description = 'Attack line for a pump.'
},

['scba_tank'] = {
    label = 'SCBA cylinder',
    weight = 7000,
    stack = false,
    close = true,
    description = 'Breathing air for interior work.'
},

['jaws_of_life'] = {
    label = 'Jaws of life',
    weight = 9000,
    stack = false,
    close = true,
    description = 'Hydraulic spreader and cutter.'
},

['halligan_bar'] = {
    label = 'Halligan bar',
    weight = 3000,
    stack = false,
    close = true,
    description = 'Forcible entry tool.'
},

['fd_medbag'] = {
    label = 'Medical bag',
    weight = 5000,
    stack = false,
    close = true,
    description = 'Patient assessment and treatment kit.'
},

['thermal_camera'] = {
    label = 'Thermal imaging camera',
    weight = 2000,
    stack = false,
    close = true,
    description = 'Sees through smoke.'
},

['hazmat_kit'] = {
    label = 'Hazmat containment kit',
    weight = 8000,
    stack = false,
    close = true,
    description = 'Absorbent and containment gear.'
},
```

## What the job does with them

- `Config.Firefighter.items.issued` is handed over at the locker when a
  firefighter clocks on and taken back when they clock off.
- `apparatus[].carries` is handed over with the apparatus and taken back when it
  is returned, so the jaws live on the rescue truck rather than in a pocket.
- A nozzle needs its item in hand, and an extrication stage needs the tool that
  stage names. Rename any of them in `Config.Firefighter.items`.

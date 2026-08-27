# Ox Core

Ox Core has no jobs, only groups, so a department is a group and a rank is a
grade within it. The bridge maps `setJob` onto `player.setGroup`.

Add the three groups to your Ox Core group definitions with six grades each:

```lua
-- ox_core groups
lsfd = {
    label = 'Los Santos Fire Department',
    grades = {
        { label = 'Probationary' },
        { label = 'Firefighter' },
        { label = 'Engineer' },
        { label = 'Lieutenant' },
        { label = 'Captain' },
        { label = 'Battalion Chief' },
    }
},
-- safd and bcfd the same way
```

## Notes

- The Ox Core adapter is best effort: its player API moves between releases, so
  every probe is guarded and degrades to "unsupported" rather than guessing. If
  hiring does not work on your build, the startup line says so and you can wire
  it up yourself:

  ```lua
  DAG.Framework.ExtendAdapter('ox', {
      setJob = function(source, job, grade)
          local player = exports.ox_core:GetPlayer(source)
          if not player then return false end
          player.setGroup(job, grade)
          return true
      end
  })
  ```

- Ox Core reports the highest-grade group as the active job, so a firefighter
  who is also in another group at a higher grade may read as that instead. Keep
  the fire grades meaningful relative to your other groups.
- Items are `ox_inventory`; see [ox_inventory.md](ox_inventory.md).

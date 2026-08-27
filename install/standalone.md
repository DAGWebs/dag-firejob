# Standalone (no framework)

The job runs with no framework at all. There are no jobs to define and no items
to add: duty is granted by ACE, and equipment checks are skipped because the
bridge reports no inventory.

```cfg
# Anyone in the group can clock on at that department's stations
add_ace group.firefighter dag-firejob.lsfd.duty allow
add_ace group.firefighter dag-firejob.safd.duty allow
add_ace group.firefighter dag-firejob.bcfd.duty allow

# Officers: hire, promote, dismiss, clear calls
add_ace group.admin dag-firejob.lsfd.command allow

# Administration: dispatch anywhere, wipe the board, award XP
add_ace group.admin dag-firejob.admin allow

add_principal identifier.license:0000000000000000000000000000000000000000 group.firefighter
```

## What changes without a framework

- **Hiring is off.** The standalone adapter can set an in-memory job, so
  `/dag-firejob:fdhire` works for the session, but nothing persists it. ACE is
  the durable grant.
- **Items are skipped.** `Config.Firefighter.items.enforce = 'auto'` sees no
  inventory and stops checking, so nozzles and the jaws work without them.
- **Pay is in-memory.** The standalone adapter keeps balances in a table that
  resets on restart. Wire real persistence in with `ExtendAdapter` if you want
  payouts to mean anything.
- **Careers still persist.** XP, certifications, and stats go to SQL when a
  driver is running, and to `data/storage.json` when one is not, so the academy
  and the leaderboard work either way.

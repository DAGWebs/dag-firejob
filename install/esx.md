# ESX

ESX keeps both jobs and items in the database, so both are SQL imports.

```sh
mysql -u user -p database < sql/esx_jobs.sql
mysql -u user -p database < sql/esx_items.sql   # skip if you run ox_inventory
mysql -u user -p database < sql/firefighter.sql # or leave migrate on
```

`sql/esx_jobs.sql` inserts `lsfd`, `safd` and `bcfd` into `jobs`, and six grades
each into `job_grades`, numbered 0 to 5 to match
`Config.Firefighter.ranks[].grade`.

## Notes

- ESX's `setJob` returns nothing, so the bridge re-reads the job afterwards to
  confirm a hire actually took. A hire that silently fails is reported as
  "the framework refused the job change" rather than being assumed to have
  worked.
- ESX has no duty concept of its own. The job tracks duty itself, and
  `Config.Firefighter.syncFrameworkDuty` is a no-op unless you extend the
  adapter:

  ```lua
  DAG.Framework.ExtendAdapter('esx', {
      setDuty = function(source, onDuty)
          -- your server's duty implementation
          return true
      end
  })
  ```

- Running `ox_inventory` alongside ESX is supported and common; use
  [ox_inventory.md](ox_inventory.md) for the items and skip `esx_items.sql`.

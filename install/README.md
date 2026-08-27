# Installing the firefighter job

The job runs on every framework the bridge supports, but jobs and items are
stored in a different place on each one. Nothing in this directory is loaded by
the resource: these are the snippets you paste into your framework so it knows
about the three departments and the eight pieces of equipment.

| Framework | Job definitions | Item definitions |
| --- | --- | --- |
| QBCore / QBus | `qb-core/shared/jobs.lua` — see [qb-core.md](qb-core.md) | `qb-core/shared/items.lua`, or ox_inventory |
| Qbox | `qbx_core/shared/jobs.lua` — see [qbox.md](qbox.md) | ox_inventory (required by Qbox) |
| ESX | `sql/esx_jobs.sql` | `sql/esx_items.sql`, or ox_inventory |
| Ox Core | groups — see [ox_core.md](ox_core.md) | ox_inventory |
| vRP | not supported for hiring; assign roles in your fork | your fork's inventory |
| Standalone | none; use ACE — see [standalone.md](standalone.md) | none; items are skipped |

Servers running `ox_inventory` on **any** framework should use
[ox_inventory.md](ox_inventory.md) for the items rather than the framework's own
item list, because the bridge routes item calls to ox_inventory when it is
started.

## Order of work

1. Import `sql/firefighter.sql`, or leave `Config.Firefighter.database.migrate`
   on and let the resource create its own tables on first start.
2. Add the job definitions for your framework, from the table above. The grades
   have to match `Config.Firefighter.ranks[].grade` (0 to 5).
3. Add the items, unless the framework has no inventory. Set
   `Config.Firefighter.items.enforce = false` to run the job without items at
   all.
4. Give somebody the ACE to run the department, so they can hire everybody
   else:

   ```cfg
   add_ace group.admin dag-firejob.lsfd.command allow
   add_ace group.admin dag-firejob.admin allow
   ```

5. Start the resource and read the line it prints. If it says the framework
   cannot change jobs, hiring is off and the job has to be assigned by hand;
   everything else still works.

## What the job needs from the framework

| The job asks for | Used by | If unsupported |
| --- | --- | --- |
| `getJob` | duty gate, hiring | ACE grants duty instead |
| `setJob` | hire, dismiss, promote | hiring is disabled |
| `addMoney` | call payouts | calls pay nothing |
| `removeMoney` | academy fees | courses are free |
| `getItemCount` / `addItem` | equipment gating and issue | items are skipped |
| `setDuty` | clocking on and off | duty is tracked here only |

The startup line names anything missing before it matters.

## Billing

The department keeps its own invoice ledger and settles through the bridge's
money methods, so billing works on every framework with no extra resource. Where
a billing resource *is* running it is mirrored into, so the invoice also shows up
where your players already look for one:

| Resource | What it gets | Configure |
| --- | --- | --- |
| `esx_billing` | A bill in the ESX billing table | `billing.provider = 'esx_billing'` |
| `qb-phone` | An invoice on the phone | `billing.provider = 'qb-phone'` |
| none | The terminal is the only place it appears | `billing.provider = 'internal'` |

`billing.settlement` decides who actually takes the money. `framework` hands the
invoice over end to end, which is the most native option but means the framework
decides where the money goes and the revenue split cannot apply. `department`
keeps the ledger here and moves the money through the framework's own accounts,
which is what a revenue split or department-funded wages need. `auto` picks
between them and prints which it chose.

Collected fees go to the department account, which is tracked here. When
`qb-management` or `esx_addonaccount` is running it is credited alongside so the
rest of the server sees the money — set `billing.society.account` to the society
name your server uses (`lsfd` by default, matching the job name).

Provider event names live in `Config.Firefighter.billing.providers`. A fork that
renamed `qb-phone:client:AddInvoice` is retargeted there rather than in the
module.

## Job definitions

The job reads them from wherever your framework keeps them — `shared/jobs.lua`
on QBCore and Qbox, the `jobs` and `job_grades` tables on ESX, groups on Ox Core
— and says at startup when a department points at a job or a grade the framework
does not define. Fix the warning before hiring anybody: hiring into a grade the
framework has never heard of is refused rather than leaving somebody in a job
that does not work.

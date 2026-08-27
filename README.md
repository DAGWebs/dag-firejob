# DAG FiveM framework template

A resource-development SDK that works **alongside** Qbox, QBCore/QBus, ESX,
legacy vRP, Ox Core, or framework-free FiveM. It does not replace the active
framework and it never owns framework jobs, players, accounts, or inventories.
Instead, it lets a job script, banking app, stock market, garage, or other
resource call those framework features through one stable API.

The included menu, command, interaction, repository, and access helpers remove
boilerplate from the resource you are building. They are deliberately generic;
there is no second job system, society system, or player database hidden here.

`modules/firefighter/` is the exception, and it is a worked example rather than
a second framework: a complete firefighter job built entirely on those helpers.
It is documented at the end of this file and can be deleted in one directory.

## Install

1. Rename this directory for your resource and place it in `resources`.
2. Ensure the framework (and `ox_inventory` for Qbox/Ox Core) before this resource.
3. Add `ensure your-resource-name` to `server.cfg`.
4. Delete the `<resource>:menu` and `<resource>:framework` demo commands in
   `client/main.lua` and `server/main.lua` once you no longer need them.
5. Start the server and read the capability line it prints (see below).

No framework dependency is declared in the manifest, so standalone mode remains
possible. If more than one core is running, `Config.FrameworkPriority` decides.

## Unsupported operations return nil, not a plausible default

This is the most important thing to know about the bridge.

Not every framework can answer every question. Ox Core models jobs as groups,
vRP forks disagree about money, and standalone has no concept of either until
you wire one up. When the active adapter cannot implement a method:

- **reads** (`GetJob`, `GetMoney`) return `nil`
- **writes** (`AddMoney`, `SetDuty`, `CreateUseableItem`) return `false`
- a one-time line is printed naming the framework and the missing method

A read that returned `0` or `{ name = 'unemployed' }` would be worse than one
that errors, because a job gate would silently deny every player — or worse,
accidentally match a policy entry. Write your gates to treat `nil` as a denial:

```lua
local job = DAG.Framework.GetJob(source)
if not job or job.name ~= 'mechanic' then return end
```

On start, the resource prints the active framework and anything it cannot do:

```
[my-resource] framework adapter: ox
[my-resource] unsupported on this framework: createUseableItem, registerCallback
```

Check that line before shipping. `Config.ReportCapabilities = false` silences
it; `DAG.Framework.MissingCapabilities()` returns the same list at runtime, and
`DAG.Framework.Supports('setDuty')` tests one method.

## Wrapper API

Access the wrapper as `DAG.Framework` (`Bridge` below). Server methods:

```lua
local Bridge = DAG.Framework

Bridge.Detect()                          -- qbox/qb/esx/vrp/ox/standalone
Bridge.Is('qb')
Bridge.IsReady()
Bridge.AwaitReady(10000)
Bridge.Supports('setDuty')               -- feature detection
Bridge.MissingCapabilities()             -- everything this framework lacks

Bridge.GetPlayer(source)                 -- native framework player, or nil
Bridge.GetIdentifier(source)             -- always resolves (license fallback)
Bridge.GetName(source)                   -- always resolves (engine fallback)
Bridge.GetJob(source)                    -- normalized job table, or nil
Bridge.GetMoney(source, 'bank')          -- number, or nil if unsupported
Bridge.AddMoney(source, 'cash', 100, 'reward')
Bridge.RemoveMoney(source, 'cash', 25, 'purchase')
Bridge.TransferMoney(source, target, 'bank', 25, 'transfer')
Bridge.HasItem(source, 'water', 1)
Bridge.GetItemCount(source, 'water')
Bridge.AddItem(source, 'water', 1, metadata)
Bridge.RemoveItem(source, 'water', 1)
Bridge.InventoryProvider()               -- 'ox' or 'framework'
Bridge.Notify(source, 'Hello!', 'success', 5000)
Bridge.HasPermission(source, 'dag.admin')
Bridge.SetDuty(source, true)
Bridge.CreateUseableItem('water', function(source, item) end)
Bridge.RegisterCallback('my-resource:getData', function(source, reply, value)
    reply({ identifier = Bridge.GetIdentifier(source), value = value })
end)
```

Client methods:

```lua
local Bridge = DAG.Framework
local player = Bridge.GetPlayerData()
local job = Bridge.GetJob()              -- nil when nothing has loaded
Bridge.Notify('Hello!', 'success', 5000)
Bridge.TriggerCallback('my-resource:getData', function(result, err)
    if err then return end
    print(json.encode(result))
end, 'example')

Bridge.On('playerLoaded', function(playerData) end)
Bridge.On('playerUnloaded', function() end)
Bridge.On('jobUpdated', function(job) end)
```

Other resources can retrieve the same wrapper on either side:

```lua
local Bridge = exports['your-resource-name']:GetFrameworkBridge()
```

### Validation the bridge performs for you

- Money amounts must be positive and finite; `NaN` and `inf` are rejected.
- Item amounts must be positive **integers**.
- `RemoveMoney` re-reads the balance and refuses to overdraw. If the balance
  cannot be read, the removal is refused rather than attempted blind.
- `RemoveItem` refuses to take more than the player holds.
- `TransferMoney` refunds the sender if the recipient credit fails, and logs a
  `CRITICAL` line if the refund itself fails. It is still not a database
  transaction — see the banking notes below.

### Callbacks

Internal callback names, lifecycle event names, and the commands this template
registers are all derived from the current resource name, so multiple resources
created from this template can run together without sharing callback channels
or fighting over a command name. Use `Bridge.Event('name')` for your own
normalized local event names.

QBCore and ESX have native callback transports and the bridge uses them. Where
there is none, the built-in transport is used: it times out after
`Config.CallbackTimeout` (the client callback receives `nil, 'timeout'`),
replies at most once per request, contains handler errors, and applies a
per-player token bucket (`Config.CallbackRateLimit`) so one client cannot drive
unbounded server work by spamming the event.

Treat every client-provided value as untrusted and authorize in the callback.

## Provider selection and capabilities

Framework selection and inventory/notification provider selection are separate.
This lets an ESX or QBCore server use `ox_inventory` and `ox_lib` without
changing its player framework. Set `Config.Inventory` or `Config.Notify` to
`framework` to force native behavior.

> On Qbox and Ox Core the framework-native inventory **is** `ox_inventory`, so
> `Config.Inventory = 'framework'` behaves identically to `auto` there.

| Area | Qbox | QB/QBus | ESX | Ox Core | vRP | Standalone |
| --- | --- | --- | --- | --- | --- | --- |
| Identity | Yes | Yes | Yes | Yes | Yes | Engine fallback |
| Job | Yes | Yes | Yes | From groups | Extend | In-memory |
| Money | Yes | Yes | Yes | Cash only | Extend | In-memory |
| Inventory | ox_inventory | Native/ox | Native/ox | ox_inventory | Extend | In-memory |
| Useable items | Yes | Yes | Yes | Extend | Extend | Extend |
| Duty | Yes | Yes | Extend | Flag only | Extend | Yes |
| Client lifecycle events | Yes | Yes | Yes | Yes | Extend | Yes (state bag) |

"Extend" means the method is not implemented and the bridge reports it as
unsupported — add it with `ExtendAdapter` (below).

The Qbox, QBCore, ESX and standalone adapters are the well-trodden paths. The
**Ox Core adapter is best effort**: its player API changes between releases, so
every probe is guarded and degrades to "unsupported" rather than guessing.
The **vRP adapter covers identity only** — see below.

## Extending an adapter

Add framework methods from your own resource without editing the bundled files:

```lua
DAG.Framework.ExtendAdapter('vrp', {
    getMoney = function(source, account)
        local id = exports.vrp:getUserId(source)
        return id and exports.vrp:getBankMoney(id) or nil
    end,
    addMoney = function(source, account, amount)
        local id = exports.vrp:getUserId(source)
        if not id then return false end
        exports.vrp:giveBankMoney(id, amount)
        return true
    end
})
```

Adapter methods must return `true` on success and `false` on failure. Returning
an unverified `true` defeats the bridge's guards — the ESX adapter re-reads the
balance after a mutation for exactly this reason.

To add a whole framework: add its resource names to `Bridge.resourceNames`, add
its key to `Config.FrameworkPriority`, and create `bridge/client/<name>.lua`
and `bridge/server/<name>.lua` that call `Bridge.RegisterAdapter`. The
structural tests enforce that those three stay in sync.

### vRP

vRP forks share almost nothing but a name. vRP1 exposes its API through
`Proxy.getInterface`, which needs `@vrp/lib/utils.lua` in the manifest and
would make this template hard-depend on vRP. The bundled adapter therefore
probes `exports.vrp:getUserId` for identity and implements nothing else, so
economy and inventory calls report as unsupported instead of silently failing.
Use `ExtendAdapter` to wire in your fork.

## Menus

`DAG.Menu` renders one normalized menu definition through whichever provider is
available. `Config.Menu = 'auto'` picks Ox Lib, then `qb-menu`, then the
**bundled NUI menu in `ui/`** — a self-contained interface with no CDN, no
`ox_lib` and no `qb-menu` dependency. Set `Config.Menu = 'nui'` to use it even
on servers that have `ox_lib` installed.

```lua
DAG.Menu.Register({
    id = 'my-resource:garage',
    title = 'Los Santos Customs',
    subtitle = 'Sandy Shores branch',
    options = {
        { title = 'Vehicle', header = true },
        {
            title = 'Repair vehicle',
            description = 'Restores engine and body health',
            icon = 'wrench',
            badge = '$1,250',
            badgeTone = 'accent',
            serverEvent = 'my-resource:repair'
        },
        { title = 'Respray', icon = 'car', menu = 'my-resource:colours' },
        { title = 'Engine condition', icon = 'info', badge = '68%', progress = 68 },
        { title = 'Impound', icon = 'lock', disabled = true, badge = 'Locked', badgeTone = 'danger' }
    }
})

DAG.Menu.Open('my-resource:garage')
```

### Option fields

| Field | Effect |
| --- | --- |
| `title` | Row label. |
| `description` | Secondary line, clamped to two lines. |
| `icon` | A built-in glyph name, or any text/emoji rendered as-is. |
| `badge` / `badgeTone` | Right-aligned pill. Tones: `accent`, `success`, `danger`. |
| `progress` | 0-100 meter under the row, for durability/stock. |
| `header` | Renders a section label; not selectable. |
| `disabled` | Dimmed and unselectable. |
| `menu` | Opens a submenu and pushes a breadcrumb. |
| `keepOpen` | Leaves the menu open after selection. |
| `onSelect` / `event` / `serverEvent` | What the selection does. `args` is passed through. |

Built-in icons: `chevron`, `back`, `check`, `close`, `lock`, `user`, `car`,
`box`, `cash`, `wrench`, `info`. Anything else is rendered as text, so emoji
work without bundling an icon font.

### Navigation

Selecting an option with `menu` pushes onto a trail, so the UI shows a
breadcrumb and a Back affordance. `Menu.Open` from outside resets the trail;
`Menu.Back()` pops one level and closes at the root. Selecting an option closes
the menu unless it sets `keepOpen`.

```lua
DAG.Menu.Open(id)        DAG.Menu.Back()        DAG.Menu.Close()
DAG.Menu.Navigate(id)    DAG.Menu.Current()     DAG.Menu.Unregister(id)
DAG.Menu.Confirm('Delete vehicle?', 'This cannot be undone.', function(ok) end)
DAG.Menu.Input('Vehicle label', { { name = 'label', label = 'Label', required = true } }, function(values, err) end)
```

`Confirm` registers a single reusable menu and tears it down once answered, and
the callback fires at most once no matter how the dialog is dismissed.

### Theming the bundled menu

```lua
Config.MenuTheme = {
    accent = '#4c8dff',
    width = 384,        -- px
    position = 'right'  -- right, left, center, top
}
```

Every colour in `ui/style.css` is a CSS custom property on `.root`, so deeper
restyling means editing that one block. Keyboard control is arrow keys, Enter,
Backspace (back) and Escape (close); mouse hover and click work throughout.

### Previewing without running FiveM

Open `tests/ui/preview.html` in any browser. It embeds the real `ui/` files and
feeds them sample menus — icons, badges, meters, submenus, long scrolling lists,
the empty state — with live accent, width and position controls. Nothing to
install, and it is the fastest way to iterate on the design.

Handlers never cross into the browser: the NUI provider sends only display
fields and gets back an index, so `onSelect`, `serverEvent` and `args` stay in
Lua.

### Adding a provider

```lua
DAG.Menu.RegisterProvider('my-ui', {
    open = function(view) end,   -- view: id, title, subtitle, breadcrumb, canGoBack, options
    close = function() end
})
```

Call `DAG.Menu.Select(index)` from your provider when a row is chosen, and
`DAG.Menu.Back()` for a back action.

## Commands

Server commands go through `DAG.Commands.Register`, which provides console
rules, ACE/framework permissions, chat suggestions (replayed to players who
join later), error containment, and a consistent handler signature.

```lua
DAG.Commands.Register('mycommand', function(source, args, rawCommand)
    -- Always validate args and ownership on the server.
end, {
    permission = 'my-resource.admin',
    help = 'Example protected command',
    arguments = { { name = 'id', help = 'Record ID' } },
    allowConsole = false
})
```

`permission` is checked against ACE first, then the framework adapter, so
`add_ace group.admin my-resource.admin allow` works on every framework
including standalone.

Command names registered by this template are derived from the resource name,
so two resources built from it never collide. The chat fallback registers
`/<resource-name>:select` (override with `Config.ChatSelectCommand`) and is only
used when `Config.Menu = 'chat'`.

## Interactions

Register world interactions without depending on a target resource. The helper
draws a marker, shows the prompt for the **closest eligible** entry, and can
open a normalized menu or invoke a callback/event. Authorization for valuable
actions must still happen on the server.

```lua
DAG.Interactions.Register({
    id = 'mechanic:clock-in',
    coords = vector3(-347.1, -133.4, 39.0),
    label = 'Press ~INPUT_CONTEXT~ to open the mechanic menu',
    distance = 2.0,
    menu = 'mechanic:main',
    canInteract = function()
        local job = DAG.Framework.GetJob()
        return job ~= nil and job.name == 'mechanic'
    end
})

DAG.Interactions.Remove('mechanic:clock-in')
DAG.Interactions.Clear()
```

## Resource-owned storage and repositories

`DAG.Storage` is a small JSON-backed CRUD store intended for
configuration-sized records. It supplies `Get`, `All`, `Set`, `Update`,
`Delete`, `Find`, and `Save`. Reads and writes are deep-copied, so callers
cannot reach into the store by holding onto a returned table. Writes are
batched using `Config.Storage.saveInterval` (floored at 1000ms) and flushed
when the resource stops. A record that cannot be serialized fails that one
write with a logged reason instead of killing the save thread.

It is only for data owned by your resource. Do not copy framework player, job,
balance, or inventory state into it. **Do not use it for high-volume financial
transactions** — replace it with a transactional database driver for a
production banking app or stock exchange.

`DAG.Repository.Create` gives your resource a named CRUD repository with
optional validation and authorization. Validation failures return
`nil, message` rather than throwing, because they are usually driven by client
input and should not unwind the handler that produced them:

```lua
local watchlists = DAG.Repository.Create('stock_watchlists', {
    validate = function(record)
        return type(record.owner) == 'string' and type(record.symbols) == 'table',
            'A watchlist requires an owner and symbols'
    end
})

local saved, err = watchlists.save(identifier, { owner = identifier, symbols = { 'DAG' } })
if not saved then return DAG.Framework.Notify(source, err, 'error') end

watchlists.update(identifier, { symbols = { 'DAG', 'LSC' } })
watchlists.count()
watchlists.delete(identifier)
```

`DAG.Access.Allowed` supports public records, an owner, ACE permission, minimum
framework job grades, and members with per-action permissions. A job that
cannot be read is a denial, never a match. Repository authorization is always
server-side.

## What building alongside a framework looks like

### A job resource

Use the framework job as the authority, then add only the gameplay owned by
your resource:

```lua
RegisterNetEvent('mechanic:server:repairVehicle', function(networkId)
    local source = source
    local job = DAG.Framework.GetJob(source)
    if not job or job.name ~= 'mechanic' or job.grade < 1 then return end
    if not DAG.Framework.RemoveItem(source, 'repairkit', 1) then return end

    -- Validate the entity and distance here, then perform the repair workflow.
end)
```

The same pattern can support any framework job or role. Keep the job name,
grades, locations, menus, equipment, and gameplay rules in the resource you
build; the template only provides the normalized primitives.

### A banking app

Read and mutate the framework account through the bridge. Store only app-owned
data such as transfer descriptions or user preferences in your repository:

```lua
local balance = DAG.Framework.GetMoney(source, 'bank')
if not balance then return end   -- this framework cannot report accounts

local moved, reason = DAG.Framework.TransferMoney(source, target, 'bank', amount, 'bank-transfer')
```

Real transfers require a database transaction, idempotency key, rate limiting,
and an audit ledger; the JSON example store is not a financial ledger.

### A stock market

Keep orders, executions, and portfolios in transactional resource-owned tables.
Use `DAG.Framework.GetIdentifier` for the character key and bridge money
methods only at validated deposit/withdrawal boundaries. The framework
continues to own the player's bank balance; the stock resource owns market
state.

## Layout

```text
ui/                        bundled NUI menu (index.html, style.css, app.js)
bridge/
├── shared.lua             detection, job normalization, event namespacing
├── client.lua             normalized client API and callback transport
├── client/<framework>.lua client adapters
├── server.lua             validation and normalized server API
└── server/<framework>.lua server adapters
modules/
├── access/                record authorization policies
├── commands/              command registration and permissions
├── interactions/          world markers and prompts
├── menu/                  normalized menus across providers
├── repository/            named CRUD repositories
├── storage/               JSON-backed persistence
└── firefighter/           the bundled firefighter job (see below)
    ├── config.lua         stations, apparatus, call types, ranks, pay
    ├── shared.lua         ranks, certifications, suppression arithmetic
    ├── server/            state, incident simulation, dispatch, pay, net API
    └── client/            mirror, rendering, rescue, station, HUD, menus
```

## Tests

Behaviour is tested by loading the real resource files against a FiveM native
stub, so the tests exercise the code the server runs rather than matching
source text:

```bash
lua5.4 tests/lua/run.lua              # 232 behavioural tests
python3 -m unittest discover -s tests # manifest/adapter/config invariants
luacheck .                            # lint
find . -name '*.lua' -not -path './.git/*' -print0 | xargs -0 -n1 luac5.4 -p
```

`tests/lua/harness.lua` stubs the natives the template touches (resource state,
events, state bags, exports, storage files, markers, controls, NUI messages and
focus) plus the entity world the firefighter job reads and writes: player peds,
vehicles, blips, script fires, weapons, and animations. The firefighter specs
drive the real simulation through it — `spec_firefighter_shared.lua`,
`spec_firefighter_server.lua`, and `spec_firefighter_client.lua`. For the menu's appearance, open `tests/ui/preview.html` in a browser. Add a
`tests/lua/spec_*.lua` file and register it in `tests/lua/run.lua` to cover new
behaviour. All four commands run in CI on every push.

## The firefighter job

`modules/firefighter/` is a complete, framework-agnostic firefighter job built
on the primitives above. It uses the framework for the things the framework
owns — the job name and grade, the bank account, duty state, notifications —
and keeps everything it invented (XP, training sign-offs, career stats) in its
own repository. Delete the directory and its five manifest entries and the
template is exactly what it was.

### What it does

- **Dispatch.** Seven call types (structure, vehicle, brush, industrial,
  hazmat, extrication, automatic alarm) are drawn from configured locations
  while at least one firefighter is on duty, weighted so working fires come up
  more often than alarms. Two calls never land at the same address.
- **A fire that behaves like one.** Every call is a set of fire nodes with an
  intensity. Unworked nodes grow to a ceiling and can spread to a new seat of
  fire; a node knocked down to zero keeps residual heat and can flare back up,
  so a crew that leaves before overhaul gets called back to the same building.
- **Water that runs out.** A hose draws from an apparatus parked within reach,
  an extinguisher from what you are carrying, and a deck monitor from the pump.
  Tanks are refilled from real hydrant props, and litres are billed against the
  supply that actually delivered them.
- **Patients.** Victims are trapped, freed, treated, and transported, in that
  order, and deteriorate while they wait. Extrication needs technical rescue,
  treatment needs EMS, containment needs hazmat.
- **Apparatus.** Six units, each gated by a certification, signed out of a
  station garage and returned to it, with the water tank tracked server side.
- **Careers.** XP per call, six ranks that each unlock certifications and a pay
  multiplier, lifetime stats, and a department leaderboard.
- **Interface.** Station fixtures are `DAG.Interactions` entries, every screen
  is a `DAG.Menu` definition (so it renders through ox_lib, qb-menu, the
  bundled NUI menu, or chat), and an on-duty HUD shows air, tank, and what is
  still outstanding on the call.

### Getting on duty

Duty is granted by `Config.Firefighter.access.duty`, which is a `DAG.Access`
policy: a framework job, an ACE permission, or both. On a framework that cannot
report jobs — standalone included — the ACE entry is what makes the job usable:

```cfg
add_ace group.admin dag-firejob.fire.duty allow
add_ace group.admin dag-firejob.fire.command allow
add_ace group.admin dag-firejob.fire.admin allow
```

Stand on a station duty point and press `E`, use the menu (`F6`), or run
`/<resource>:duty`. Commands are prefixed with the resource name for the same
reason the rest of the template does it; set `Config.Firefighter.commandPrefix`
to `fd` for `/fd:duty`.

| Command | Who | What |
| --- | --- | --- |
| `<prefix>:duty` | Firefighters | Clock on or off at a station |
| `<prefix>:roster` | Anyone | Who is on duty and what they are on |
| `<prefix>:fdcall <type> [here]` | `access.admin` | Dispatch a call, optionally at your feet |
| `<prefix>:fdclear [callId]` | `access.command` | Close one call, or all of them |
| `<prefix>:fdcert <playerId> <cert>` | `access.command` | Sign a firefighter off for training |
| `<prefix>:fdxp <playerId> <amount>` | `access.admin` | Adjust an XP total |

`<prefix>:fdmenu` (bound to **F6**) opens the department menu, and
`<prefix>:fdhose` toggles a hose line without going through it.

### Where authority sits

Everything a client can ask for is re-checked against state the server owns:

- Distances are measured from `GetEntityCoords(GetPlayerPed(source))`, never
  from a coordinate the client sent, so a spray, an extrication, or a hydrant
  connection from across the map fails.
- Water reports are rate limited per player, capped per report, checked against
  the agent's range, and billed to a supply that has to exist and be in reach.
- Extrication, treatment, and containment are two-phase: the server records the
  start, and a completion that comes back early or from somewhere else is
  refused. The client only draws the progress bar.
- Payouts, XP, and promotions are computed at close from the server's own
  ledger of who arrived and how much water they put on it.
- The apparatus tank lives on the server. A spawned vehicle is only registered
  once the server has confirmed the entity really is the model it authorized.

The one thing taken on trust is the position of a hydrant prop, because the
server cannot enumerate map objects; the player and their apparatus still have
to be standing at the coordinates they report, so a forged hydrant buys water
at the truck's own position and nothing more.

### Configuration

`Config.Firefighter` is declared in `config.lua` and filled in by
`modules/firefighter/config.lua`, which is where every coordinate and balance
number lives:

```lua
Config.Firefighter.dispatch.interval = { min = 180000, max = 420000 }
Config.Firefighter.fire.spreadChance = 0.16      -- per tick, per call
Config.Firefighter.scba.drainInSmoke = 4         -- litres of air per second
Config.Firefighter.pay.minimumShare = 0.35       -- guaranteed slice of a split
Config.Firefighter.enforceCertifications = true  -- false makes ranks cosmetic
Config.Firefighter.enabled = false               -- switch the whole job off
```

Stations, apparatus, call types, and their incident locations are lists: adding
a station or a call type is adding a table entry, not editing a module. The
bundled coordinates are stock GTA V locations and are worth tuning for your map.

### Extending it

The job is exported as a whole:

```lua
local Fire = exports['your-resource-name']:GetFirefighter()

Fire.Dispatch.Create('structure', { coords = vector3(...), label = 'Motel 6' })
Fire.Progression.GrantCertification(identifier, 'hazmat')
Fire.Progression.Leaderboard(10)
Fire.State.Roster()
```

Client-side, `Fire.Client` is the mirror of dispatch, `Fire.Suppression` is the
renderer and nozzle, and `Fire.Menus.Refresh()` rebuilds every menu from the
current state — registering a menu id again is the supported way to update a
live board.

Things deliberately left as extension points, because they cannot be done
framework-agnostically: turnout gear as clothing (ped components differ per
framework and per clothing resource), item-backed equipment (wire
`Bridge.HasItem` into `Suppression.Equip` if your server wants an SCBA item),
and MDT/scanner integration (subscribe to the `fire:radio` client event).

## License

MIT — see [LICENSE](LICENSE).

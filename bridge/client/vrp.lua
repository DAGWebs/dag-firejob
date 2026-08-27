-- vRP does not expose a consistent client-side player object across forks.
-- With no methods registered, the bridge falls back to the replicated
-- `dagPlayer` state bag and chat notifications, and reports the missing
-- capabilities at startup. Use DAG.Framework.ExtendAdapter('vrp', { ... })
-- to add your fork's client API.
DAG.Framework.RegisterAdapter('vrp', {})

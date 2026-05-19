# Decisions

## 001: Money Uses an Immutable Ledger

Balances are derived from `wallet_ledger` deltas. Rows cannot be updated or deleted. Corrections must be new ledger entries.

## 002: No Client Money Writes

Authenticated clients receive SELECT access to their own wallet ledger rows only. They receive no INSERT, UPDATE, or DELETE policy on `wallet_ledger`.

## 003: Defer Dirty Money

Phase 1 stores clean-cash ledger deltas only. Dirty cash, laundering jobs, fees, and risk scores belong to Phase 6.

## 004: Use Integer Minor Units

Money fields use `bigint` minor units to avoid floating-point drift.

## 005: Keep Phase 1 Catalogs Read-Only

`market_items` and `inventory_items` can be read by authenticated clients but changed only by trusted server roles.

## 006: Serialize Player Money Mutations

Purchase operations use `pg_advisory_xact_lock(hashtextextended(player_id::text, 0))` before reading the ledger balance and inserting money deltas. Future money-changing RPCs must take the same per-player lock.

## 007: Keep Privileged RPC Logic Outside the Public Schema

The public RPC function is a thin invoker wrapper. Privileged writes live in the private schema with a fixed empty search path and fully qualified object names.

## 008: Edge Function Must Preserve Caller Auth Context

`buy-item` validates the JWT with an admin client, but invokes `purchase_item` with a publishable or anon client that forwards the caller's `Authorization` header. This keeps `auth.uid()` inside Postgres equal to the player derived from the JWT.

## 009: Per-Function Deno Configuration

The `buy-item` function owns its `deno.json` dependency map. Shared function-level configuration, including `verify_jwt = true`, lives in `supabase/config.toml`.

## 010: Market Ticks Are Server-Only

The Railway economy engine uses `SUPABASE_SERVICE_ROLE_KEY` and a shared `TICK_SECRET`. It does not accept player identity or client money instructions.

## 011: Damped Market Movement

Market ticks move `current_price` toward `base_price * demand / supply` using `MARKET_DAMPING`, defaulting to `0.05`. Prices are clamped to each item's `min_price` and `max_price`.

## 012: Price Updates and History Are Atomic

The economy engine calls `apply_market_price_update`, a service-role-only RPC. The database updates `market_items.current_price` and inserts `market_price_history` in one transaction.

## 013: Audit Money Mutations in Database Triggers

`wallet_ledger` and `transactions` inserts are audited by Postgres triggers into `audit_events`. This makes the audit trail independent from Edge Function or engine code paths.

## 014: Engine Runs Are System Jobs

Every economy-engine tick records a `system_jobs` row. The job starts before work begins and is completed or failed after the tick finishes.

## 015: Dirty Cash Is a Ledger Currency

Dirty cash uses `wallet_ledger.currency = 'cash_dirty'`. There are no mutable wallet columns. Laundering creates negative dirty-cash entries on start and positive clean-cash entries only on completion.

## 016: Laundering Uses the Same Auth Pattern as Purchases

The `start-laundering` Edge Function validates JWTs with an admin client, but calls `start_laundering` with the caller's authorization header. Postgres remains responsible for the `auth.uid()` ownership guard.

## 017: District Prices Are Derived Snapshots

District-specific prices live in `district_prices`, but the global market remains the baseline. The district tick applies local demand, supply disruption, prosperity, security, heat, crime pressure, and active event modifiers, then writes only changed prices.

## 018: World Event Activity Is Queried, Not Generated

Postgres generated columns cannot safely depend on volatile time functions. `world_events.active` is an operator-controlled flag, and the engine also filters by `start_time <= now < end_time`.

## 019: District Price Updates and History Are Atomic

The economy engine calls `apply_district_price_update`, a service-role-only RPC. The database upserts `district_prices` and inserts `district_price_history` in one transaction.

## 020: NPCs Are Cohorts, Not Actors

Phase 8 simulates population pressure through `npc_cohorts`. A district has a small number of aggregate cohort rows instead of thousands of mutable NPC records.

## 021: NPC Ticks Change District Conditions

NPC demand does not directly edit item prices. `/tick/npc` updates district `demand_multiplier`, `crime_pressure`, and `heat_level`; `/tick/district` later turns those local conditions into price snapshots.

## 022: NPC Tick Logs Are District Summaries

`npc_tick_log` records one append-only summary row per changed district. `cohort_type` is nullable because summary rows represent all cohorts in that district, not a fake enum member.

## 023: Agents Are Not Fake Auth Users

`profiles.id` references Supabase Auth users, so autonomous agents do not get synthetic profile rows. Agents use dedicated `agents`, `agent_wallet_ledger`, and `agent_inventory` tables.

## 024: Agent Actions Use Service-Only RPCs

Player RPCs depend on `auth.uid()` and must stay client-authenticated. The economy engine mutates agent state through separate service-role-only RPCs so autonomous behavior cannot weaken player money authorization.

## 025: Stablecoins Start Simulated

Stablecoin mechanics will begin with simulated ledger currencies only. Real USDC or USDT movement requires testnet validation, reconciliation, legal review, and explicit production gates.

## 026: Simulated Stablecoin Uses Minor Units

`sim_usdt` and `sim_usdc` are stored as integer minor units in the immutable ledgers. Initial simulated rates are near 1:1 with `cash_clean` minor units, and spread is applied in basis points.

## 027: Crypto Exchange Preserves Auth Context

`exchange-crypto` validates the JWT with a service-role client but invokes `exchange_currency` with the caller's authorization header. The database remains responsible for the `auth.uid()` player guard.

## 028: Dirty Cash Cannot Enter Crypto in Phase 11-Sim

Only `cash_clean`, `sim_usdt`, and `sim_usdc` are exchangeable. Dirty-cash to crypto flows are deferred because they need stronger risk controls and game-balance gates.

## 029: Police Heat Is Economic Pressure

Police response changes district `police_presence`, `checkpoint_level`, and `supply_disruption`. The first implementation avoids teleporting enforcement into player wallets; it makes crime pressure readable through prices, disruption, incidents, and player heat.

## 030: Bribes Preserve Auth Context

`bribe-police` validates the JWT with a service-role client but invokes `bribe_police` with the caller's authorization header. The database remains responsible for the `auth.uid()` guard and the immutable clean-cash ledger sink.

## 031: Player Heat Is Separate From District Heat

District `heat_level` drives public enforcement pressure. `player_heat` is per-player and per-district, readable only by that player, and can only be mutated by trusted database functions or service-role setup paths.

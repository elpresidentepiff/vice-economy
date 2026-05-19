# Vice Economy Engine

Server-authoritative multiplayer economy backend built around Supabase, PostgreSQL, Railway, and a Node.js TypeScript service.

## Mission

Money first. The first deliverable is a secure economy database where authenticated players can read their own wallet state and inventory, but cannot create or mutate money from the client.

## Current Scope

This repository currently implements Phase 0 through Phase 12:

- Monorepo structure
- Supabase core schema migration
- Row Level Security policies
- Immutable wallet ledger foundation
- Seed market items
- Buildable placeholder economy engine package
- Atomic `purchase_item` RPC for market purchases
- Supabase Edge Function for `POST /functions/v1/buy-item`
- Railway-ready economy engine with `/health` and `/tick/market`
- Audit events and system job observability
- Dirty-money laundering MVP with `/tick/launder`
- District economy with `/tick/district` and district-specific prices
- NPC cohort demand simulation with `/tick/npc`
- Text-only Unreal integration plugin and REST smoke test
- Agent economy MVP with `/tick/agents`
- Simulated stablecoin exchange with `/tick/crypto` and `POST /functions/v1/exchange-crypto`
- Police heat enforcement with `/tick/police` and `POST /functions/v1/bribe-police`

Out of scope for this phase:

- Unreal assets, maps, meshes, Blueprints, DDC, and generated project files

## Repository Layout

```text
vice-economy/
+-- docs/
+-- supabase/
|   +-- migrations/
|   +-- functions/
|   +-- seed.sql
+-- economy-engine/
|   +-- src/
|   +-- Dockerfile
|   +-- package.json
+-- unreal-plugin/
+   +-- Source/
+   +-- README.md
+   +-- vice-economy.uplugin
+-- scripts/
+-- .env.example
+-- README.md
+-- docker-compose.yml
```

## Local Build

From this directory:

```bash
npm install
npm run build
```

The economy engine builds the TypeScript heartbeat service used by market, district, NPC, agent, laundering, and simulated crypto ticks.

## Supabase Migration

Apply the core schema with:

```bash
supabase db push
```

Then seed initial market items:

```bash
supabase db reset
```

or run `supabase/seed.sql` through your normal local Supabase workflow.

## Edge Function

Deploy the authenticated purchase endpoint with:

```bash
supabase functions deploy buy-item
```

Invoke it as an authenticated user:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/buy-item" \
  -H "Authorization: Bearer $USER_ACCESS_TOKEN" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"item_id":"water_bottle","quantity":1,"player_id":"spoofed-id-is-ignored"}'
```

The request body never accepts a trusted `player_id`. The function derives the player from the JWT and the database RPC verifies the same identity with `auth.uid()`.

Dirty-money laundering uses the same pattern:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/start-laundering" \
  -H "Authorization: Bearer $USER_ACCESS_TOKEN" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"business_id":"...","amount":5000,"player_id":"spoofed-id-is-ignored"}'
```

Simulated crypto exchange also preserves the caller's JWT context:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/exchange-crypto" \
  -H "Authorization: Bearer $USER_ACCESS_TOKEN" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"from_currency":"cash_clean","to_currency":"sim_usdt","amount":1000,"player_id":"spoofed-id-is-ignored"}'
```

Only `cash_clean`, `sim_usdt`, and `sim_usdc` are exchangeable in the simulation. Dirty cash cannot be exchanged into crypto in Phase 11-Sim.

Police bribes use the same JWT-preserving pattern:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/bribe-police" \
  -H "Authorization: Bearer $USER_ACCESS_TOKEN" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"district_id":"port","amount":500,"player_id":"spoofed-id-is-ignored"}'
```

The bribe RPC deducts `cash_clean` through `wallet_ledger`, records a `bribe` transaction, lowers existing `player_heat`, and writes an immutable `bribe_events` row.

## Economy Engine

Run locally:

```bash
npm run build
TICK_SECRET=replace-me SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... npm --workspace economy-engine start
```

Build and run the Docker image from the repository root:

```bash
docker build -f economy-engine/Dockerfile -t vice-economy-engine .
docker run -p 3000:3000 --env-file .env vice-economy-engine
```

Health check:

```bash
curl http://localhost:3000/health
```

Market tick:

```bash
curl -X POST http://localhost:3000/tick/market \
  -H "x-tick-secret: replace-me"
```

Laundering tick:

```bash
curl -X POST http://localhost:3000/tick/launder \
  -H "x-tick-secret: replace-me"
```

District tick:

```bash
curl -X POST http://localhost:3000/tick/district \
  -H "x-tick-secret: replace-me"
```

NPC cohort tick:

```bash
curl -X POST http://localhost:3000/tick/npc \
  -H "x-tick-secret: replace-me"
```

Agent tick:

```bash
curl -X POST http://localhost:3000/tick/agents \
  -H "x-tick-secret: replace-me"
```

Crypto rate tick:

```bash
curl -X POST http://localhost:3000/tick/crypto \
  -H "x-tick-secret: replace-me"
```

Police tick:

```bash
curl -X POST http://localhost:3000/tick/police \
  -H "x-tick-secret: replace-me"
```

Combined tick:

```bash
curl -X POST http://localhost:3000/tick/all \
  -H "x-tick-secret: replace-me"
```

For Railway, set `RAILWAY_DOCKERFILE_PATH=economy-engine/Dockerfile` and provide `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TICK_SECRET`, and `NODE_ENV=production`.

## Unreal Integration

The repository includes a lightweight Unreal plugin in `unreal-plugin/`. It contains C++ source only. Keep the full Unreal project and all binary assets in a separate asset repository or cloud store.

Run the REST smoke test:

```bash
npm run test:unreal-integration
```

See `docs/unreal-integration-guide.md` for setup.

## Security Posture

- RLS is enabled on all public tables.
- Authenticated users can read their own profile, wallet ledger rows, transaction rows, and inventory.
- Authenticated users can read their current clean-cash balance through `wallet_balances`.
- Authenticated users cannot insert, update, or delete wallet ledger rows.
- Wallet ledger rows are immutable. Corrections must be represented as new reversal entries.
- Market and inventory catalog data is read-only to clients.
- `audit_events` and `market_price_history` are append-only.
- District catalog and price snapshots are client-readable but service-writable only.
- District price history is append-only.
- NPC cohorts are aggregated, client-readable population groups; clients cannot mutate them.
- NPC tick logs are append-only.
- Agents have separate immutable wallets and inventories; player wallet auth is not weakened for autonomous engine actions.
- Agent wallet ledgers and action logs are append-only.
- Simulated crypto balances are ledger currencies, not mutable wallet fields.
- Exchange spread revenue is recorded in `crypto_spread_revenue`; clients cannot read or write that table.
- Police pressure is a district-level economic modifier. Clients can read district police state and incidents, but only the economy engine can update enforcement.
- Player heat and bribe events are player-readable only. Bribes are clean-cash ledger sinks and cannot spoof `player_id`.
- Economy engine runs are tracked in `system_jobs`.

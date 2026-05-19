# Vice Economy Engine

Server-authoritative multiplayer economy backend built around Supabase, PostgreSQL, Railway, and a Node.js TypeScript service.

## Mission

Money first. The first deliverable is a secure economy database where authenticated players can read their own wallet state and inventory, but cannot create or mutate money from the client.

## Current Scope

This repository currently implements Phase 0 through Phase 7:

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

Out of scope for this phase:

- NPC simulation
- Unreal integration

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

The economy engine is still a placeholder. It exists so the repository has a build gate before service logic is added in a later phase.

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

Combined tick:

```bash
curl -X POST http://localhost:3000/tick/all \
  -H "x-tick-secret: replace-me"
```

For Railway, set `RAILWAY_DOCKERFILE_PATH=economy-engine/Dockerfile` and provide `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TICK_SECRET`, and `NODE_ENV=production`.

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
- Economy engine runs are tracked in `system_jobs`.

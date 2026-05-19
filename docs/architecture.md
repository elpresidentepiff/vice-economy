# Architecture

## Principle

Vice Economy Engine is server-authoritative. Clients send intent; the database and trusted server code decide whether money changes.

## Phase 1 Components

- Supabase Auth supplies player identity.
- PostgreSQL stores economy state.
- RLS limits client reads to owned rows.
- The wallet ledger is the source of truth for money changes.
- Market catalog tables are client-readable but not client-writable.

## Money Model

Money is represented as immutable clean-cash deltas in `wallet_ledger`.

The current wallet balance is exposed through the read-only `wallet_balances` view, which sums `delta_amount` for the authenticated player under the underlying table RLS policies. Dirty cash is intentionally deferred until the dirty-money phase.

Client applications must never update balances directly. Future purchase, sale, and laundering flows must write ledger entries through trusted RPCs or Edge Functions.

## Purchase Flow

`public.purchase_item` is the Phase 2 RPC entrypoint. It validates `p_player_id` against `auth.uid()` and delegates to a private security-definer implementation.

The implementation uses a transaction-scoped advisory lock keyed by player ID, then locks the selected market item row. This serializes purchases for the same player while still allowing different players to purchase concurrently.

## Edge Function Layer

`POST /functions/v1/buy-item` is the Phase 3 client-facing purchase endpoint.

The function validates the caller's JWT, derives `player_id` from Supabase Auth, validates only `item_id` and `quantity` from the request body, and forwards the caller's `Authorization` header when invoking `purchase_item`. That preserves the database-level `auth.uid()` check inside the RPC.

```mermaid
flowchart LR
  Client["Game client"] --> Edge["buy-item Edge Function"]
  Edge --> Auth["Supabase Auth getUser"]
  Edge --> RPC["public.purchase_item"]
  RPC --> Ledger["wallet_ledger append"]
  RPC --> Inventory["player_inventory upsert"]
  RPC --> Transactions["transactions append"]
```

## Economy Engine

The Phase 4 economy engine is a Node.js service intended for Railway. It exposes:

- `GET /health`: public readiness check.
- `POST /tick/market`: protected by `x-tick-secret`.

The engine uses the Supabase service-role key because it is a trusted server worker, not a client proxy. It writes market price changes directly and records every change in `market_price_history` with a shared `tick_id`.

## Audit Layer

Phase 5 adds `audit_events` and `system_jobs`.

`wallet_ledger` and `transactions` inserts are mirrored into `audit_events` by database triggers. This keeps money mutation audit inside Postgres, not inside application code.

The economy engine writes a `system_jobs` row for each `/tick/market` run, then marks it `completed` or `failed`. Price changes remain grouped by `market_price_history.tick_id`.

## Dirty Money

Dirty money is stored in the same immutable `wallet_ledger` as clean cash, distinguished by `currency = 'cash_dirty'`.

Players start laundering through `start_laundering`, which immediately inserts a negative dirty-cash ledger row and creates a pending `laundering_jobs` record. The economy engine later calls `complete_laundering` through `/tick/launder`; only then does the player receive clean cash, net of fees.

## Trust Boundaries

- Browser or game client: untrusted.
- Supabase RLS: defensive wall for user-scoped reads.
- Service role callers: trusted server path only.
- Database functions: transaction-safe authority for money changes in later phases.

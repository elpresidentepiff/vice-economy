# Phase Roadmap

## Phase 0: Repository Setup

Status: implemented.

Goal: create a clean monorepo foundation with docs, Supabase folders, a placeholder economy engine package, Dockerfile, environment example, and build scripts.

Gate: repository builds locally.

## Phase 1: Supabase Foundation

Status: implemented.

Goal: create secure database foundations for profiles, wallet ledger, market catalog, player inventory, and transaction history.

Gate: a normal authenticated user can read owned economy state but cannot mutate cash.

## Later Phases

## Phase 2: Atomic Purchase RPC

Status: implemented.

Goal: allow authenticated players to buy active market items without permitting client-side money writes or double-spends.

The `purchase_item` RPC validates the caller, serializes purchases per player with a transaction-scoped advisory lock, locks the market item row, computes clean cash from the immutable ledger, inserts a transaction, inserts a negative ledger delta, and upserts inventory.

Gate: no double-spend possible.

## Later Phases

## Phase 3: Supabase Edge Function

Status: implemented and deployed.

Goal: expose `POST /functions/v1/buy-item` so clients submit purchase intent without sending a trusted player ID.

The function derives `player_id` from the JWT, validates `item_id` and `quantity`, and calls `purchase_item` under the caller's authorization context.

Gate: spoofing another user ID in the request body does not affect the purchase. Verified against the deployed function at `https://ltbsxbvfsxtnharjvqcm.supabase.co/functions/v1/buy-item`.

## Phase 4: Railway Economy Engine

Status: implemented and Docker-verified locally; Railway deployment pending GitHub/Railway project setup.

Goal: run a Node.js heartbeat service with public `/health` and protected `/tick/market` endpoints.

The market tick fetches active market items, calculates `base_price * demand / supply`, damps movement toward the target, clamps within item price bounds, writes `market_price_history`, and updates `market_items.current_price`.

Gate: `/health` returns 200 OK and a valid `/tick/market` request updates prices and writes history. Verified locally through the Docker image against cloud Supabase.

## Later Phases

## Phase 5: Market History and Audit

Status: implemented and Docker-verified against cloud Supabase.

Goal: make money-changing operations and engine jobs traceable before dirty money is introduced.

The database writes `audit_events` on every `wallet_ledger` and `transactions` insert. Audit and market history tables are append-only. The economy engine writes `system_jobs` records for market ticks.

Gate: every money mutation has an audit row, market history is append-only, and every engine tick has a system job record. Verified with tick `14ee98e6-ee32-4ed5-9c0f-c229323abf57`.

## Phase 6: Dirty Money MVP

Status: implemented and Docker-verified against cloud Supabase.

Goal: introduce dirty cash, player-owned laundering businesses, time-delayed laundering jobs, fees, risk scores, and engine-side job completion.

Gate: insufficient dirty cash fails, business capacity failures are enforced, dirty cash decreases immediately, clean cash increases only after completion, fees are deducted, and audit events are written for each money step. Verified through deployed `start-laundering` and Docker `/tick/launder`.

## Phase 7: District Economy

Status: implemented and Docker-verified against cloud Supabase.

Goal: make market prices spatial by district, with local prices reacting to prosperity, security, heat, supply disruption, demand, crime pressure, and active world events.

The district tick reads global `market_items.current_price` as the baseline, applies district and event multipliers, damps movement toward the target, clamps within item price bounds, and writes snapshots plus `district_price_history` through the service-role-only `apply_district_price_update` RPC.

Gate: `/tick/district` updates district-specific prices, active world events influence affected district/item pairs, no unauthenticated tick can run, and district price history records every change. Verified with tick `c32d3130-20b9-4960-a207-471fe5c8a520`, where a temporary Port storm moved `water_bottle` from 274 to 296 and wrote 12 district history rows.

## Later Phases

Phases 8 through 9 are intentionally not implemented yet. The next phase is NPC cohort demand simulation.

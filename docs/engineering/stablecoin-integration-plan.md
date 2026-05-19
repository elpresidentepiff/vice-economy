# Stablecoin Integration Plan

Stablecoins belong in Vice Economy, but not before the simulated money path is boringly correct. This plan keeps real financial risk out of the early phases while preserving a clean path to USDC or USDT later.

## Principle

No real-money movement until the simulated ledger proves:

- every credit and debit is immutable,
- every spread and fee is traceable,
- every exchange action has a reversible audit trail,
- every high-risk flow can be rate-limited or disabled,
- no client can mint, withdraw, or alter balances directly.

## Phase 11-Sim: Simulated Stablecoins

Goal: add crypto-like currencies to the existing economy without connecting to a blockchain.

Currencies:

- `cash_clean`
- `cash_dirty`
- `sim_usdc`
- `sim_usdt`

Deliverables:

- Migration `011_sim_crypto.sql`
- Extend ledger and transaction currency constraints
- `crypto_exchange_rates`
- `crypto_spread_revenue`
- `exchange_crypto` RPC
- `exchange-crypto` Edge Function
- `/tick/crypto` oracle simulation endpoint
- `scripts/test-crypto-exchange.ts`

Rules:

- Client sends exchange intent only.
- Server reads the current rate and spread.
- Source balance is checked from immutable ledger sums.
- Debit and credit are separate ledger rows tied to one transaction or exchange id.
- Spread revenue is recorded explicitly.
- Simulated minting is service-role only and allowed only for test faucet/admin flows.

Gate:

- no real assets move,
- no client can mint,
- exchange cannot overdraft,
- fee/spread is traceable,
- concurrent exchanges cannot double-spend.

## Exchange Model

Example: clean cash to simulated USDC.

1. Player requests `cash_clean -> sim_usdc`.
2. RPC locks the player with the existing advisory-lock pattern.
3. RPC reads current exchange rate and spread.
4. RPC inserts:
   - negative `cash_clean` ledger row,
   - positive `sim_usdc` ledger row net of spread,
   - spread revenue record,
   - transaction row with metadata.
5. RPC returns success/failure.

The reverse direction follows the same structure.

## Phase 11-Testnet

Goal: connect the same interface to testnet USDC.

Requirements:

- non-custodial wallet connection,
- testnet faucet only,
- deposit watcher,
- withdrawal queue,
- idempotency keys,
- chain confirmation policy,
- operator pause switch,
- reconciliation job.

Gate:

- no mainnet,
- no production funds,
- deposits and withdrawals reconcile exactly,
- duplicate webhook or chain events do not double-credit.

## Phase 11-Real

Goal: enable real stablecoin movement only after legal, compliance, and security review.

Required before launch:

- legal review for jurisdictions served,
- KYC/AML policy,
- sanctions screening decision,
- smart contract audit if contracts are used,
- multisig treasury,
- withdrawal limits,
- suspicious activity monitoring,
- incident response runbook,
- explicit user disclosures.

## Monetization

Potential revenue paths:

- exchange spread,
- withdrawal fee,
- premium settlement speed,
- marketplace fee on player-to-player asset sales,
- business licensing fees inside the game economy.

All revenue must be recorded in ledger-compatible tables so finance, audit, and gameplay telemetry agree.

## Agent Integration

Agents can hold simulated stablecoins once Phase 11-Sim is live. Criminal and investor roles should prefer `sim_usdt` or `sim_usdc` for high-value trades. This should be introduced only after Phase 10 agent actions are stable in shadow mode.

## Hard No List

- No service-role key in clients.
- No real mainnet assets during simulation.
- No client-side minting.
- No hidden fees.
- No off-ledger balance changes.
- No withdrawals without reconciliation.

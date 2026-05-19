# Unreal Integration Guide

Phase 9 keeps Unreal integration deliberately small: REST first, no custom networking plugin, no committed assets, and no Unreal project in this repository.

## Repository Boundary

Commit to `vice-economy`:

- `unreal-plugin/`
- C++ source
- plugin descriptor
- setup documentation
- REST smoke tests

Do not commit:

- `Content/`
- `Intermediate/`
- `Saved/`
- `.uproject` binaries or generated files
- DDC
- meshes, materials, maps, textures, animations, audio, or Blueprint asset binaries

Keep the full Unreal project in a separate asset/versioning system such as Git LFS, Perforce, Azure Blob, or Google Drive. Use Unreal Cloud DDC for derived data.

## Install Plugin

Copy or symlink:

```text
vice-economy/unreal-plugin/
```

into:

```text
YourGame/Plugins/ViceEconomy/
```

Then regenerate project files and build the Unreal project.

## Runtime Flow

1. Player authenticates through your chosen auth UI.
2. Store the Supabase user access token in memory.
3. Get `UEconomyManager` from the game instance.
4. Set `SupabaseUrl`, `AnonKey`, and `SetUserJWT`.
5. Fetch wallet, inventory, market items, and district prices.
6. Send purchase or laundering intent through Edge Functions.

```cpp
UEconomyManager* Economy = GetGameInstance()->GetSubsystem<UEconomyManager>();
Economy->SupabaseUrl = TEXT("https://ltbsxbvfsxtnharjvqcm.supabase.co");
Economy->AnonKey = TEXT("<anon-or-publishable-key>");
Economy->SetUserJWT(PlayerAccessToken);
Economy->FetchWalletBalance();
Economy->FetchDistrictPrices(TEXT("vice_beach"));
```

## Endpoints Used

- `GET /rest/v1/wallet_balances?select=cash_clean,cash_dirty&limit=1`
- `GET /rest/v1/player_inventory?select=item_id,quantity`
- `GET /rest/v1/market_items?select=item_id,display_name,category,current_price`
- `GET /rest/v1/district_prices?select=district_id,item_id,current_price&district_id=eq.<district>`
- `POST /functions/v1/buy-item`
- `POST /functions/v1/start-laundering`

`wallet_balances`, `player_inventory`, and `market_items` are called with the player's JWT. `district_prices` is public-readable. The Unreal client must never call service-role endpoints or write money tables directly.

## Realtime

Start with polling district prices every few seconds. Supabase Realtime can be added later with a lightweight WebSocket wrapper if polling becomes too coarse.

## Verification

Run the REST smoke test from the repository root:

```bash
npm run test:unreal-integration
```

By default it checks public district, district price, and NPC cohort reads. If `TEST_PLAYER_EMAIL` and `TEST_PLAYER_PASSWORD` are set, it also checks authenticated market, wallet, and inventory reads.

Mutating checks are disabled by default. To opt in:

```bash
RUN_MUTATING_UNREAL_TESTS=true npm run test:unreal-integration
```

Only run mutating checks against a disposable test player.

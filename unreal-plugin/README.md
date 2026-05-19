# Vice Economy Unreal Plugin

This folder is intentionally text-only. Do not commit a full Unreal project, `Content/`, `Intermediate/`, `Saved/`, DDC, meshes, maps, textures, or generated binaries to `vice-economy`.

## Cloud Asset Strategy

- Keep this repository for backend code, docs, and the lightweight Unreal integration plugin.
- Store the full Unreal project and `Content/` assets in a separate Unreal repo with Git LFS, Perforce, Azure Blob, Google Drive, or another team asset store.
- Use Unreal Cloud DDC for derived data cache. Do not put DDC output in any Git repository.
- Copy or symlink this `unreal-plugin/` folder into the Unreal project's `Plugins/ViceEconomy/` directory.

## Install

1. Copy this folder into your Unreal project:

   ```text
   YourGame/
   +-- Plugins/
       +-- ViceEconomy/
           +-- vice-economy.uplugin
           +-- Source/
   ```

2. Regenerate project files.
3. Enable the `Vice Economy` plugin if Unreal prompts you.
4. Build the project.

## Configure

Get the subsystem from C++:

```cpp
UEconomyManager* Economy = GetGameInstance()->GetSubsystem<UEconomyManager>();
Economy->SupabaseUrl = TEXT("https://ltbsxbvfsxtnharjvqcm.supabase.co");
Economy->AnonKey = TEXT("<supabase anon or publishable key>");
Economy->SetUserJWT(PlayerAccessToken);
```

The anon or publishable key is safe for clients. Never put the service-role key in Unreal.

## Blueprint Usage

The subsystem exposes Blueprint-callable methods:

- `SetUserJWT`
- `FetchWalletBalance`
- `FetchInventory`
- `FetchMarketItems`
- `FetchDistrictPrices`
- `BuyItem`
- `StartLaundering`

Bind widgets to:

- `OnWalletUpdated`
- `OnInventoryUpdated`
- `OnMarketItemsUpdated`
- `OnDistrictPricesUpdated`
- `OnRequestFailed`

## Notes

`FetchWalletBalance`, `FetchInventory`, `FetchMarketItems`, `BuyItem`, and `StartLaundering` require the player's JWT. `FetchDistrictPrices` is public-readable. The client sends intent only; money changes stay server-authoritative.

For live price updates, start with polling `FetchDistrictPrices` on a timer. Add Supabase Realtime later only if polling becomes a real problem.

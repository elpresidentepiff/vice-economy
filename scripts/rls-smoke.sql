-- Run against a local Supabase database after applying migrations.
-- Replace the UUIDs with real auth.users IDs from your local project.

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

-- Expected: returns only the active catalog rows.
select item_id, current_price
from public.market_items
order by item_id;

-- Expected: fails because authenticated clients have no INSERT policy or grant.
insert into public.wallet_ledger (player_id, delta_amount, reason)
values ('00000000-0000-0000-0000-000000000001', 999999, 'client cheat attempt');

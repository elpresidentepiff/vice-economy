-- Run after applying 003_purchase_item.sql.
-- This script uses a transaction and rolls back all test writes.
-- Replace the UUID with an auth.users.id from your Supabase project.

begin;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

insert into public.profiles (id, display_name)
values ('00000000-0000-0000-0000-000000000001', 'phase-2-test-player')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.wallet_ledger (player_id, delta_amount, reason)
values ('00000000-0000-0000-0000-000000000001', 1000, 'phase_2_test_grant');

set local role authenticated;

select public.purchase_item(
  '00000000-0000-0000-0000-000000000001',
  'water_bottle',
  2
) as valid_purchase;

select public.purchase_item(
  '00000000-0000-0000-0000-000000000001',
  'missing_item',
  1
) as invalid_item;

select public.purchase_item(
  '00000000-0000-0000-0000-000000000001',
  'burner_phone',
  1
) as insufficient_funds;

-- Expected: permission error.
select public.purchase_item(
  '11111111-1111-1111-1111-111111111111',
  'water_bottle',
  1
) as spoofed_player;

rollback;


begin;

alter table public.wallet_ledger
  drop constraint wallet_ledger_currency_check;

alter table public.wallet_ledger
  add constraint wallet_ledger_currency_check
  check (currency in ('cash_clean', 'cash_dirty', 'sim_usdt', 'sim_usdc'));

alter table public.transactions
  drop constraint transactions_currency_check;

alter table public.transactions
  add constraint transactions_currency_check
  check (currency in ('cash_clean', 'cash_dirty', 'sim_usdt', 'sim_usdc'));

alter table public.transactions
  drop constraint transactions_transaction_type_check;

alter table public.transactions
  add constraint transactions_transaction_type_check
  check (transaction_type in (
    'grant',
    'purchase',
    'sale',
    'adjustment',
    'laundering_start',
    'laundering_complete',
    'crypto_exchange',
    'crypto_faucet',
    'crypto_fee'
  ));

alter table public.agent_wallet_ledger
  drop constraint agent_wallet_ledger_currency_check;

alter table public.agent_wallet_ledger
  add constraint agent_wallet_ledger_currency_check
  check (currency in ('cash_clean', 'cash_dirty', 'sim_usdt', 'sim_usdc'));

drop view if exists public.wallet_balances;

create or replace view public.wallet_balances
with (security_invoker = true)
as
select
  p.id as player_id,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_clean'), 0)::bigint as cash_clean,
  max(w.created_at) as last_ledger_at,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_dirty'), 0)::bigint as cash_dirty,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'sim_usdt'), 0)::bigint as sim_usdt,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'sim_usdc'), 0)::bigint as sim_usdc
from public.profiles p
left join public.wallet_ledger w on w.player_id = p.id
group by p.id;

drop view if exists public.agent_wallet_balances;

create or replace view public.agent_wallet_balances
with (security_invoker = true)
as
select
  a.id as agent_id,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_clean'), 0)::bigint as cash_clean,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_dirty'), 0)::bigint as cash_dirty,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'sim_usdt'), 0)::bigint as sim_usdt,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'sim_usdc'), 0)::bigint as sim_usdc,
  max(w.created_at) as last_ledger_at
from public.agents a
left join public.agent_wallet_ledger w on w.agent_id = a.id
group by a.id;

create table public.crypto_exchange_rates (
  id uuid primary key default gen_random_uuid(),
  from_currency text not null check (from_currency in ('cash_clean', 'sim_usdt', 'sim_usdc')),
  to_currency text not null check (to_currency in ('cash_clean', 'sim_usdt', 'sim_usdc')),
  rate numeric(20, 8) not null check (rate > 0),
  min_rate numeric(20, 8) not null check (min_rate > 0),
  max_rate numeric(20, 8) not null check (max_rate >= min_rate),
  spread_bps integer not null default 200 check (spread_bps between 0 and 10000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (from_currency, to_currency),
  constraint crypto_exchange_rates_no_self_pair check (from_currency <> to_currency),
  constraint crypto_exchange_rates_rate_bounds check (rate between min_rate and max_rate)
);

create index crypto_exchange_rates_active_pair_idx
  on public.crypto_exchange_rates (from_currency, to_currency)
  where active = true;

create trigger crypto_exchange_rates_set_updated_at
before update on public.crypto_exchange_rates
for each row execute function public.set_updated_at();

create table public.crypto_spread_revenue (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  transaction_id uuid not null references public.transactions(id) on delete restrict,
  from_currency text not null check (from_currency in ('cash_clean', 'sim_usdt', 'sim_usdc')),
  to_currency text not null check (to_currency in ('cash_clean', 'sim_usdt', 'sim_usdc')),
  source_amount bigint not null check (source_amount > 0),
  gross_target_amount bigint not null check (gross_target_amount > 0),
  net_target_amount bigint not null check (net_target_amount > 0),
  spread_amount bigint not null check (spread_amount >= 0),
  rate numeric(20, 8) not null check (rate > 0),
  spread_bps integer not null check (spread_bps between 0 and 10000),
  created_at timestamptz not null default now(),
  constraint crypto_spread_revenue_net_lte_gross check (net_target_amount <= gross_target_amount)
);

create index crypto_spread_revenue_player_created_idx
  on public.crypto_spread_revenue (player_id, created_at desc);

create index crypto_spread_revenue_transaction_idx
  on public.crypto_spread_revenue (transaction_id);

create trigger crypto_spread_revenue_prevent_update
before update on public.crypto_spread_revenue
for each row execute function public.prevent_append_only_mutation();

create trigger crypto_spread_revenue_prevent_delete
before delete on public.crypto_spread_revenue
for each row execute function public.prevent_append_only_mutation();

alter table public.crypto_exchange_rates enable row level security;
alter table public.crypto_spread_revenue enable row level security;

create policy "crypto_exchange_rates_select_all"
on public.crypto_exchange_rates
for select
to anon, authenticated
using (active = true);

create policy "crypto_exchange_rates_service_select"
on public.crypto_exchange_rates
for select
to service_role
using (true);

create policy "crypto_exchange_rates_service_insert"
on public.crypto_exchange_rates
for insert
to service_role
with check (true);

create policy "crypto_exchange_rates_service_update"
on public.crypto_exchange_rates
for update
to service_role
using (true)
with check (true);

create policy "crypto_spread_revenue_service_select"
on public.crypto_spread_revenue
for select
to service_role
using (true);

create policy "crypto_spread_revenue_service_insert"
on public.crypto_spread_revenue
for insert
to service_role
with check (true);

revoke all on table public.crypto_exchange_rates from anon, authenticated, service_role;
revoke all on table public.crypto_spread_revenue from anon, authenticated, service_role;
revoke all on table public.wallet_balances from anon, authenticated, service_role;
revoke all on table public.agent_wallet_balances from anon, authenticated, service_role;

grant select on table public.crypto_exchange_rates to anon, authenticated;
grant select on table public.wallet_balances to authenticated;

grant select, insert, update on table public.crypto_exchange_rates to service_role;
grant select, insert on table public.crypto_spread_revenue to service_role;
grant select on table public.wallet_balances to service_role;
grant select on table public.agent_wallet_balances to service_role;

create or replace function private.exchange_currency_impl(
  p_player_id uuid,
  p_from_currency text,
  p_to_currency text,
  p_amount bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_rate public.crypto_exchange_rates%rowtype;
  v_balance bigint;
  v_gross_target bigint;
  v_spread_amount bigint;
  v_net_target bigint;
  v_transaction_id uuid;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  if p_player_id is null or p_player_id <> v_auth_uid then
    raise exception 'cannot exchange for another player' using errcode = '42501';
  end if;

  if p_from_currency is null or p_to_currency is null or p_from_currency = p_to_currency then
    return jsonb_build_object('success', false, 'error', 'invalid_pair');
  end if;

  if p_from_currency not in ('cash_clean', 'sim_usdt', 'sim_usdc')
    or p_to_currency not in ('cash_clean', 'sim_usdt', 'sim_usdc') then
    return jsonb_build_object('success', false, 'error', 'unsupported_currency');
  end if;

  if p_from_currency = 'cash_dirty' or p_to_currency = 'cash_dirty' then
    return jsonb_build_object('success', false, 'error', 'dirty_cash_exchange_disabled');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_amount');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_player_id::text, 0));

  perform 1
  from public.profiles
  where id = p_player_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'wallet_not_found');
  end if;

  select *
  into v_rate
  from public.crypto_exchange_rates
  where from_currency = p_from_currency
    and to_currency = p_to_currency
    and active = true
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'exchange_pair_not_supported');
  end if;

  select coalesce(sum(delta_amount), 0)::bigint
  into v_balance
  from public.wallet_ledger
  where player_id = p_player_id
    and currency = p_from_currency;

  if v_balance < p_amount then
    return jsonb_build_object(
      'success', false,
      'error', 'insufficient_balance',
      'available', v_balance
    );
  end if;

  v_gross_target := round(p_amount::numeric * v_rate.rate)::bigint;
  v_spread_amount := floor(v_gross_target::numeric * v_rate.spread_bps::numeric / 10000)::bigint;
  v_net_target := v_gross_target - v_spread_amount;

  if v_gross_target <= 0 or v_net_target <= 0 then
    return jsonb_build_object('success', false, 'error', 'exchange_amount_too_small');
  end if;

  insert into public.transactions (
    player_id,
    transaction_type,
    total_amount,
    currency,
    metadata
  ) values (
    p_player_id,
    'crypto_exchange',
    -p_amount,
    p_from_currency,
    jsonb_build_object(
      'from_currency', p_from_currency,
      'to_currency', p_to_currency,
      'source_amount', p_amount,
      'gross_target_amount', v_gross_target,
      'net_target_amount', v_net_target,
      'spread_amount', v_spread_amount,
      'spread_bps', v_rate.spread_bps,
      'rate', v_rate.rate,
      'simulated', true
    )
  )
  returning id into v_transaction_id;

  insert into public.wallet_ledger (
    player_id,
    delta_amount,
    currency,
    reason,
    reference_type,
    reference_id,
    metadata
  ) values
  (
    p_player_id,
    -p_amount,
    p_from_currency,
    'crypto_exchange_out',
    'transaction',
    v_transaction_id,
    jsonb_build_object(
      'to_currency', p_to_currency,
      'rate', v_rate.rate,
      'simulated', true
    )
  ),
  (
    p_player_id,
    v_net_target,
    p_to_currency,
    'crypto_exchange_in',
    'transaction',
    v_transaction_id,
    jsonb_build_object(
      'from_currency', p_from_currency,
      'gross_target_amount', v_gross_target,
      'spread_amount', v_spread_amount,
      'spread_bps', v_rate.spread_bps,
      'rate', v_rate.rate,
      'simulated', true
    )
  );

  insert into public.crypto_spread_revenue (
    player_id,
    transaction_id,
    from_currency,
    to_currency,
    source_amount,
    gross_target_amount,
    net_target_amount,
    spread_amount,
    rate,
    spread_bps
  ) values (
    p_player_id,
    v_transaction_id,
    p_from_currency,
    p_to_currency,
    p_amount,
    v_gross_target,
    v_net_target,
    v_spread_amount,
    v_rate.rate,
    v_rate.spread_bps
  );

  return jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'from_currency', p_from_currency,
    'to_currency', p_to_currency,
    'amount_sent', p_amount,
    'gross_amount_received', v_gross_target,
    'amount_received', v_net_target,
    'spread_amount', v_spread_amount,
    'spread_bps', v_rate.spread_bps,
    'rate', v_rate.rate,
    'simulated', true
  );
end;
$$;

create or replace function public.exchange_currency(
  p_player_id uuid,
  p_from_currency text,
  p_to_currency text,
  p_amount bigint
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.exchange_currency_impl(p_player_id, p_from_currency, p_to_currency, p_amount);
$$;

create or replace function public.apply_crypto_rate_update(
  p_rate_id uuid,
  p_expected_rate numeric,
  p_new_rate numeric
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_rate_id is null or p_expected_rate is null or p_new_rate is null or p_new_rate <= 0 then
    return false;
  end if;

  update public.crypto_exchange_rates
  set rate = p_new_rate
  where id = p_rate_id
    and rate = p_expected_rate
    and p_new_rate between min_rate and max_rate;

  return found;
end;
$$;

create or replace function public.apply_agent_cash_delta(
  p_agent_id uuid,
  p_delta_amount bigint,
  p_currency text,
  p_reason text,
  p_tick_id uuid default null,
  p_details jsonb default '{}'::jsonb
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_agent_id is null or p_delta_amount is null or p_delta_amount = 0 then
    return false;
  end if;

  if p_currency not in ('cash_clean', 'cash_dirty', 'sim_usdt', 'sim_usdc') then
    return false;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_agent_id::text, 0));

  perform 1
  from public.agents
  where id = p_agent_id
    and active = true
  for update;

  if not found then
    return false;
  end if;

  insert into public.agent_wallet_ledger (
    agent_id,
    delta_amount,
    currency,
    reason,
    reference_type,
    metadata
  ) values (
    p_agent_id,
    p_delta_amount,
    p_currency,
    p_reason,
    'agent_action',
    p_details || jsonb_build_object('tick_id', p_tick_id)
  );

  insert into public.agent_action_log (
    agent_id,
    action,
    details,
    tick_id
  ) values (
    p_agent_id,
    p_reason,
    p_details || jsonb_build_object(
      'delta_amount', p_delta_amount,
      'currency', p_currency
    ),
    p_tick_id
  );

  return true;
end;
$$;

insert into public.crypto_exchange_rates (
  from_currency,
  to_currency,
  rate,
  min_rate,
  max_rate,
  spread_bps
) values
  ('cash_clean', 'sim_usdt', 1.00000000, 0.90000000, 1.10000000, 200),
  ('sim_usdt', 'cash_clean', 1.00000000, 0.90000000, 1.10000000, 200),
  ('cash_clean', 'sim_usdc', 1.00000000, 0.90000000, 1.10000000, 200),
  ('sim_usdc', 'cash_clean', 1.00000000, 0.90000000, 1.10000000, 200),
  ('sim_usdt', 'sim_usdc', 1.00000000, 0.99000000, 1.01000000, 50),
  ('sim_usdc', 'sim_usdt', 1.00000000, 0.99000000, 1.01000000, 50);

revoke all on function private.exchange_currency_impl(uuid, text, text, bigint) from public, anon;
revoke all on function public.exchange_currency(uuid, text, text, bigint) from public, anon;
revoke all on function public.apply_crypto_rate_update(uuid, numeric, numeric) from public, anon, authenticated;

grant execute on function private.exchange_currency_impl(uuid, text, text, bigint) to authenticated;
grant execute on function public.exchange_currency(uuid, text, text, bigint) to authenticated;
grant execute on function public.apply_crypto_rate_update(uuid, numeric, numeric) to service_role;

commit;

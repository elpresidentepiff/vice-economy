begin;

alter table public.districts
  add column if not exists police_presence integer not null default 0 check (police_presence between 0 and 100),
  add column if not exists checkpoint_level integer not null default 0 check (checkpoint_level between 0 and 100),
  add column if not exists last_police_tick_at timestamptz;

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
    'crypto_fee',
    'bribe'
  ));

create table public.police_incidents (
  id bigint generated always as identity primary key,
  district_id text not null references public.districts(district_id) on delete restrict,
  incident_type text not null check (
    incident_type in ('patrol_increase', 'patrol_decrease', 'checkpoint', 'crackdown')
  ),
  severity integer not null default 1 check (severity between 0 and 100),
  old_police_presence integer check (old_police_presence is null or old_police_presence between 0 and 100),
  new_police_presence integer not null check (new_police_presence between 0 and 100),
  old_checkpoint_level integer check (old_checkpoint_level is null or old_checkpoint_level between 0 and 100),
  new_checkpoint_level integer not null check (new_checkpoint_level between 0 and 100),
  details jsonb not null default '{}'::jsonb,
  tick_id uuid,
  created_at timestamptz not null default now()
);

create index police_incidents_district_created_idx
  on public.police_incidents (district_id, created_at desc);

create index police_incidents_tick_idx
  on public.police_incidents (tick_id, created_at desc);

create trigger police_incidents_prevent_update
before update on public.police_incidents
for each row execute function public.prevent_append_only_mutation();

create trigger police_incidents_prevent_delete
before delete on public.police_incidents
for each row execute function public.prevent_append_only_mutation();

create table public.player_heat (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  district_id text not null references public.districts(district_id) on delete cascade,
  heat_level integer not null default 0 check (heat_level between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (player_id, district_id)
);

create index player_heat_player_district_idx
  on public.player_heat (player_id, district_id);

create index player_heat_district_idx
  on public.player_heat (district_id);

create trigger player_heat_set_updated_at
before update on public.player_heat
for each row execute function public.set_updated_at();

create table public.bribe_events (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  district_id text not null references public.districts(district_id) on delete restrict,
  amount bigint not null check (amount > 0),
  heat_before integer not null check (heat_before between 0 and 100),
  heat_after integer not null check (heat_after between 0 and 100),
  transaction_id uuid not null references public.transactions(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint bribe_events_heat_lte_before check (heat_after <= heat_before)
);

create index bribe_events_player_created_idx
  on public.bribe_events (player_id, created_at desc);

create index bribe_events_district_created_idx
  on public.bribe_events (district_id, created_at desc);

create index bribe_events_transaction_idx
  on public.bribe_events (transaction_id);

create trigger bribe_events_prevent_update
before update on public.bribe_events
for each row execute function public.prevent_append_only_mutation();

create trigger bribe_events_prevent_delete
before delete on public.bribe_events
for each row execute function public.prevent_append_only_mutation();

alter table public.police_incidents enable row level security;
alter table public.player_heat enable row level security;
alter table public.bribe_events enable row level security;

create policy "police_incidents_select_all"
on public.police_incidents
for select
to anon, authenticated
using (true);

create policy "police_incidents_service_select"
on public.police_incidents
for select
to service_role
using (true);

create policy "police_incidents_service_insert"
on public.police_incidents
for insert
to service_role
with check (true);

create policy "player_heat_select_own"
on public.player_heat
for select
to authenticated
using (player_id = auth.uid());

create policy "player_heat_service_select"
on public.player_heat
for select
to service_role
using (true);

create policy "player_heat_service_insert"
on public.player_heat
for insert
to service_role
with check (true);

create policy "player_heat_service_update"
on public.player_heat
for update
to service_role
using (true)
with check (true);

create policy "bribe_events_select_own"
on public.bribe_events
for select
to authenticated
using (player_id = auth.uid());

create policy "bribe_events_service_select"
on public.bribe_events
for select
to service_role
using (true);

create policy "bribe_events_service_insert"
on public.bribe_events
for insert
to service_role
with check (true);

revoke all on table public.police_incidents from anon, authenticated, service_role;
revoke all on table public.player_heat from anon, authenticated, service_role;
revoke all on table public.bribe_events from anon, authenticated, service_role;

grant select on table public.police_incidents to anon, authenticated;
grant select on table public.player_heat to authenticated;
grant select on table public.bribe_events to authenticated;

grant select, insert on table public.police_incidents to service_role;
grant select, insert, update on table public.player_heat to service_role;
grant select, insert on table public.bribe_events to service_role;

revoke all on sequence public.police_incidents_id_seq from anon, authenticated;
grant usage, select on sequence public.police_incidents_id_seq to service_role;

grant usage on schema private to authenticated;

create or replace function private.bribe_police_impl(
  p_player_id uuid,
  p_district_id text,
  p_amount bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_clean_balance bigint;
  v_current_heat integer;
  v_heat_reduction integer;
  v_new_heat integer;
  v_transaction_id uuid;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  if p_player_id is null or p_player_id <> v_auth_uid then
    raise exception 'cannot bribe for another player' using errcode = '42501';
  end if;

  if p_district_id is null or length(trim(p_district_id)) = 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_district_id');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_amount');
  end if;

  perform 1
  from public.districts
  where district_id = p_district_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'district_not_found');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_player_id::text, 0));

  perform 1
  from public.profiles
  where id = p_player_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'wallet_not_found');
  end if;

  select coalesce(sum(delta_amount), 0)::bigint
  into v_clean_balance
  from public.wallet_ledger
  where player_id = p_player_id
    and currency = 'cash_clean';

  if v_clean_balance < p_amount then
    return jsonb_build_object(
      'success', false,
      'error', 'insufficient_clean_cash',
      'available', v_clean_balance
    );
  end if;

  select heat_level
  into v_current_heat
  from public.player_heat
  where player_id = p_player_id
    and district_id = p_district_id
  for update;

  if not found or v_current_heat <= 0 then
    return jsonb_build_object('success', false, 'error', 'no_heat_to_reduce');
  end if;

  v_heat_reduction := least(v_current_heat, floor(p_amount::numeric / 100)::integer);

  if v_heat_reduction <= 0 then
    return jsonb_build_object('success', false, 'error', 'bribe_too_small');
  end if;

  v_new_heat := greatest(0, v_current_heat - v_heat_reduction);

  insert into public.transactions (
    player_id,
    transaction_type,
    total_amount,
    currency,
    metadata
  ) values (
    p_player_id,
    'bribe',
    -p_amount,
    'cash_clean',
    jsonb_build_object(
      'district_id', p_district_id,
      'heat_before', v_current_heat,
      'heat_after', v_new_heat,
      'heat_reduced', v_heat_reduction
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
  ) values (
    p_player_id,
    -p_amount,
    'cash_clean',
    'police_bribe',
    'transaction',
    v_transaction_id,
    jsonb_build_object(
      'district_id', p_district_id,
      'heat_before', v_current_heat,
      'heat_after', v_new_heat,
      'heat_reduced', v_heat_reduction
    )
  );

  update public.player_heat
  set heat_level = v_new_heat
  where player_id = p_player_id
    and district_id = p_district_id;

  insert into public.bribe_events (
    player_id,
    district_id,
    amount,
    heat_before,
    heat_after,
    transaction_id
  ) values (
    p_player_id,
    p_district_id,
    p_amount,
    v_current_heat,
    v_new_heat,
    v_transaction_id
  );

  return jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'district_id', p_district_id,
    'amount_paid', p_amount,
    'heat_before', v_current_heat,
    'heat_after', v_new_heat,
    'heat_reduced', v_heat_reduction
  );
end;
$$;

create or replace function public.bribe_police(
  p_player_id uuid,
  p_district_id text,
  p_amount bigint
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.bribe_police_impl(p_player_id, p_district_id, p_amount);
$$;

create or replace function public.apply_police_district_update(
  p_district_id text,
  p_expected_police_presence integer,
  p_new_police_presence integer,
  p_expected_checkpoint_level integer,
  p_new_checkpoint_level integer,
  p_expected_supply_disruption numeric,
  p_new_supply_disruption numeric,
  p_tick_id uuid,
  p_incident_type text default null,
  p_severity integer default 0,
  p_details jsonb default '{}'::jsonb
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_district_id is null
    or p_new_police_presence is null
    or p_new_checkpoint_level is null
    or p_new_supply_disruption is null
    or p_new_police_presence not between 0 and 100
    or p_new_checkpoint_level not between 0 and 100
    or p_new_supply_disruption <= 0 then
    return false;
  end if;

  update public.districts
  set
    police_presence = p_new_police_presence,
    checkpoint_level = p_new_checkpoint_level,
    supply_disruption = p_new_supply_disruption,
    last_police_tick_at = now()
  where district_id = p_district_id
    and police_presence = p_expected_police_presence
    and checkpoint_level = p_expected_checkpoint_level
    and supply_disruption = p_expected_supply_disruption;

  if not found then
    return false;
  end if;

  if p_incident_type is not null and p_severity > 0 then
    insert into public.police_incidents (
      district_id,
      incident_type,
      severity,
      old_police_presence,
      new_police_presence,
      old_checkpoint_level,
      new_checkpoint_level,
      details,
      tick_id
    ) values (
      p_district_id,
      p_incident_type,
      least(100, greatest(0, p_severity)),
      p_expected_police_presence,
      p_new_police_presence,
      p_expected_checkpoint_level,
      p_new_checkpoint_level,
      coalesce(p_details, '{}'::jsonb),
      p_tick_id
    );
  end if;

  return true;
end;
$$;

revoke all on function private.bribe_police_impl(uuid, text, bigint) from public, anon;
revoke all on function public.bribe_police(uuid, text, bigint) from public, anon;
revoke all on function public.apply_police_district_update(text, integer, integer, integer, integer, numeric, numeric, uuid, text, integer, jsonb) from public, anon, authenticated;

grant execute on function private.bribe_police_impl(uuid, text, bigint) to authenticated;
grant execute on function public.bribe_police(uuid, text, bigint) to authenticated;
grant execute on function public.apply_police_district_update(text, integer, integer, integer, integer, numeric, numeric, uuid, text, integer, jsonb) to service_role;

commit;

begin;

create table public.districts (
  district_id text primary key,
  name text not null,
  prosperity_index integer not null default 50 check (prosperity_index between 0 and 100),
  security_level integer not null default 50 check (security_level between 0 and 100),
  heat_level integer not null default 0 check (heat_level between 0 and 100),
  supply_disruption numeric not null default 1.0 check (supply_disruption > 0),
  demand_multiplier numeric not null default 1.0 check (demand_multiplier > 0),
  crime_pressure integer not null default 0 check (crime_pressure between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger districts_set_updated_at
before update on public.districts
for each row execute function public.set_updated_at();

insert into public.districts (
  district_id,
  name,
  prosperity_index,
  security_level,
  demand_multiplier,
  crime_pressure
) values
  ('port', 'Viceport', 30, 20, 1.2, 70),
  ('downtown', 'Downtown', 80, 70, 0.9, 20),
  ('suburbs', 'Suburbs', 60, 80, 1.0, 10),
  ('swamp', 'Swamplands', 20, 10, 1.5, 90),
  ('vice_beach', 'Vice Beach', 70, 40, 1.1, 50);

create table public.world_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  affected_districts text[] not null,
  price_modifiers jsonb not null default '{}'::jsonb,
  start_time timestamptz not null default now(),
  end_time timestamptz not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint world_events_has_districts check (array_length(affected_districts, 1) > 0),
  constraint world_events_valid_window check (end_time > start_time),
  constraint world_events_modifiers_object check (jsonb_typeof(price_modifiers) = 'object')
);

create index world_events_active_window_idx
  on public.world_events (active, start_time, end_time);

create trigger world_events_set_updated_at
before update on public.world_events
for each row execute function public.set_updated_at();

create table public.district_prices (
  district_id text not null references public.districts(district_id) on delete cascade,
  item_id text not null references public.market_items(item_id) on delete restrict,
  current_price bigint not null check (current_price > 0),
  last_updated timestamptz not null default now(),
  primary key (district_id, item_id)
);

create index district_prices_item_idx
  on public.district_prices (item_id);

create table public.district_price_history (
  id bigint generated always as identity primary key,
  district_id text not null references public.districts(district_id) on delete restrict,
  item_id text not null references public.market_items(item_id) on delete restrict,
  old_price bigint,
  new_price bigint not null check (new_price > 0),
  reason text not null default 'district_tick',
  tick_id uuid not null,
  created_at timestamptz not null default now()
);

create index district_price_history_tick_idx
  on public.district_price_history (tick_id, created_at desc);

create index district_price_history_district_item_idx
  on public.district_price_history (district_id, item_id, created_at desc);

create trigger district_price_history_prevent_update
before update on public.district_price_history
for each row execute function public.prevent_append_only_mutation();

create trigger district_price_history_prevent_delete
before delete on public.district_price_history
for each row execute function public.prevent_append_only_mutation();

create or replace function public.apply_district_price_update(
  p_district_id text,
  p_item_id text,
  p_expected_old_price bigint,
  p_new_price bigint,
  p_tick_id uuid,
  p_reason text default 'district_tick'
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_existing_price bigint;
begin
  if p_new_price <= 0 then
    raise exception 'district price must be positive';
  end if;

  select current_price
  into v_existing_price
  from public.district_prices
  where district_id = p_district_id
    and item_id = p_item_id
  for update;

  if found then
    if v_existing_price <> p_expected_old_price then
      return false;
    end if;

    update public.district_prices
    set
      current_price = p_new_price,
      last_updated = now()
    where district_id = p_district_id
      and item_id = p_item_id;
  else
    insert into public.district_prices (
      district_id,
      item_id,
      current_price,
      last_updated
    ) values (
      p_district_id,
      p_item_id,
      p_new_price,
      now()
    );
  end if;

  insert into public.district_price_history (
    district_id,
    item_id,
    old_price,
    new_price,
    reason,
    tick_id
  ) values (
    p_district_id,
    p_item_id,
    p_expected_old_price,
    p_new_price,
    p_reason,
    p_tick_id
  );

  return true;
end;
$$;

alter table public.districts enable row level security;
alter table public.world_events enable row level security;
alter table public.district_prices enable row level security;
alter table public.district_price_history enable row level security;

create policy "districts_select_all"
on public.districts
for select
to anon, authenticated
using (true);

create policy "world_events_select_all"
on public.world_events
for select
to anon, authenticated
using (true);

create policy "district_prices_select_all"
on public.district_prices
for select
to anon, authenticated
using (true);

create policy "district_price_history_service_select"
on public.district_price_history
for select
to service_role
using (true);

create policy "district_price_history_service_insert"
on public.district_price_history
for insert
to service_role
with check (true);

revoke all on table public.districts from anon, authenticated, service_role;
revoke all on table public.world_events from anon, authenticated, service_role;
revoke all on table public.district_prices from anon, authenticated, service_role;
revoke all on table public.district_price_history from anon, authenticated, service_role;

grant select on table public.districts to anon, authenticated;
grant select on table public.world_events to anon, authenticated;
grant select on table public.district_prices to anon, authenticated;

grant select, insert, update, delete on table public.districts to service_role;
grant select, insert, update, delete on table public.world_events to service_role;
grant select, insert, update on table public.district_prices to service_role;
grant select, insert on table public.district_price_history to service_role;

revoke all on sequence public.district_price_history_id_seq from anon, authenticated;
grant usage, select on sequence public.district_price_history_id_seq to service_role;

revoke all on function public.apply_district_price_update(text, text, bigint, bigint, uuid, text) from public, anon, authenticated;
grant execute on function public.apply_district_price_update(text, text, bigint, bigint, uuid, text) to service_role;

commit;

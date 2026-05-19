begin;

create type public.cohort_type as enum (
  'working_class',
  'wealthy',
  'tourist',
  'criminal'
);

create table public.npc_cohorts (
  id uuid primary key default gen_random_uuid(),
  district_id text not null references public.districts(district_id) on delete cascade,
  cohort_type public.cohort_type not null,
  population integer not null default 1000 check (population > 0),
  wealth_level integer not null default 50 check (wealth_level between 0 and 100),
  fear_level integer not null default 0 check (fear_level between 0 and 100),
  demand_profile jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (district_id, cohort_type),
  constraint npc_cohorts_demand_profile_object check (jsonb_typeof(demand_profile) = 'object')
);

create index npc_cohorts_district_idx
  on public.npc_cohorts (district_id);

create trigger npc_cohorts_set_updated_at
before update on public.npc_cohorts
for each row execute function public.set_updated_at();

insert into public.npc_cohorts (
  district_id,
  cohort_type,
  population,
  wealth_level,
  fear_level,
  demand_profile
) values
  ('port', 'working_class', 3000, 20, 40, '{"consumable": 1.4, "equipment": 1.0, "water_bottle": 1.3}'::jsonb),
  ('port', 'wealthy', 200, 80, 10, '{"equipment": 1.2, "burner_phone": 1.1}'::jsonb),
  ('port', 'tourist', 500, 60, 30, '{"consumable": 1.1, "street_taco": 1.2}'::jsonb),
  ('port', 'criminal', 800, 30, 20, '{"equipment": 1.5, "burner_phone": 1.4}'::jsonb),

  ('downtown', 'working_class', 2000, 30, 20, '{"consumable": 1.2, "street_taco": 1.1}'::jsonb),
  ('downtown', 'wealthy', 1500, 90, 5, '{"equipment": 1.5, "burner_phone": 1.3}'::jsonb),
  ('downtown', 'tourist', 1200, 70, 15, '{"consumable": 1.3, "street_taco": 1.4}'::jsonb),
  ('downtown', 'criminal', 400, 40, 30, '{"equipment": 1.4, "burner_phone": 1.3}'::jsonb),

  ('suburbs', 'working_class', 4000, 40, 10, '{"consumable": 1.3, "street_taco": 1.2}'::jsonb),
  ('suburbs', 'wealthy', 800, 85, 5, '{"equipment": 1.3, "burner_phone": 1.2}'::jsonb),
  ('suburbs', 'tourist', 300, 60, 5, '{"consumable": 1.1}'::jsonb),
  ('suburbs', 'criminal', 200, 35, 15, '{"equipment": 1.0, "burner_phone": 1.1}'::jsonb),

  ('swamp', 'working_class', 500, 10, 60, '{"consumable": 1.5, "water_bottle": 1.4}'::jsonb),
  ('swamp', 'wealthy', 50, 70, 20, '{"equipment": 1.2}'::jsonb),
  ('swamp', 'tourist', 100, 40, 50, '{"consumable": 1.3}'::jsonb),
  ('swamp', 'criminal', 600, 20, 40, '{"equipment": 1.7, "burner_phone": 1.5}'::jsonb),

  ('vice_beach', 'working_class', 2500, 45, 25, '{"consumable": 1.3, "street_taco": 1.1}'::jsonb),
  ('vice_beach', 'wealthy', 1000, 85, 10, '{"equipment": 1.3, "burner_phone": 1.2}'::jsonb),
  ('vice_beach', 'tourist', 2000, 65, 20, '{"consumable": 1.4, "street_taco": 1.3}'::jsonb),
  ('vice_beach', 'criminal', 500, 30, 35, '{"equipment": 1.4, "burner_phone": 1.3}'::jsonb);

create table public.npc_tick_log (
  id bigint generated always as identity primary key,
  tick_id uuid not null,
  district_id text not null references public.districts(district_id) on delete restrict,
  log_scope text not null default 'district_summary' check (log_scope in ('district_summary')),
  cohort_type public.cohort_type,
  old_demand_multiplier numeric,
  new_demand_multiplier numeric,
  old_crime_pressure integer,
  new_crime_pressure integer,
  old_heat_level integer,
  new_heat_level integer,
  cohort_count integer not null default 0 check (cohort_count >= 0),
  total_population integer not null default 0 check (total_population >= 0),
  avg_fear numeric,
  avg_wealth numeric,
  event_fear_delta integer not null default 0,
  created_at timestamptz not null default now()
);

create index npc_tick_log_tick_idx
  on public.npc_tick_log (tick_id, created_at desc);

create index npc_tick_log_district_idx
  on public.npc_tick_log (district_id, created_at desc);

create trigger npc_tick_log_prevent_update
before update on public.npc_tick_log
for each row execute function public.prevent_append_only_mutation();

create trigger npc_tick_log_prevent_delete
before delete on public.npc_tick_log
for each row execute function public.prevent_append_only_mutation();

create or replace function public.apply_npc_district_update(
  p_district_id text,
  p_expected_demand_multiplier numeric,
  p_new_demand_multiplier numeric,
  p_expected_crime_pressure integer,
  p_new_crime_pressure integer,
  p_expected_heat_level integer,
  p_new_heat_level integer,
  p_tick_id uuid,
  p_cohort_count integer,
  p_total_population integer,
  p_avg_fear numeric,
  p_avg_wealth numeric,
  p_event_fear_delta integer
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.districts
  set
    demand_multiplier = p_new_demand_multiplier,
    crime_pressure = p_new_crime_pressure,
    heat_level = p_new_heat_level
  where district_id = p_district_id
    and demand_multiplier = p_expected_demand_multiplier
    and crime_pressure = p_expected_crime_pressure
    and heat_level = p_expected_heat_level;

  if not found then
    return false;
  end if;

  insert into public.npc_tick_log (
    tick_id,
    district_id,
    log_scope,
    cohort_type,
    old_demand_multiplier,
    new_demand_multiplier,
    old_crime_pressure,
    new_crime_pressure,
    old_heat_level,
    new_heat_level,
    cohort_count,
    total_population,
    avg_fear,
    avg_wealth,
    event_fear_delta
  ) values (
    p_tick_id,
    p_district_id,
    'district_summary',
    null,
    p_expected_demand_multiplier,
    p_new_demand_multiplier,
    p_expected_crime_pressure,
    p_new_crime_pressure,
    p_expected_heat_level,
    p_new_heat_level,
    p_cohort_count,
    p_total_population,
    p_avg_fear,
    p_avg_wealth,
    p_event_fear_delta
  );

  return true;
end;
$$;

alter table public.npc_cohorts enable row level security;
alter table public.npc_tick_log enable row level security;

create policy "npc_cohorts_select_all"
on public.npc_cohorts
for select
to anon, authenticated
using (true);

create policy "npc_tick_log_service_select"
on public.npc_tick_log
for select
to service_role
using (true);

create policy "npc_tick_log_service_insert"
on public.npc_tick_log
for insert
to service_role
with check (true);

revoke all on table public.npc_cohorts from anon, authenticated, service_role;
revoke all on table public.npc_tick_log from anon, authenticated, service_role;

grant select on table public.npc_cohorts to anon, authenticated;

grant select, insert, update, delete on table public.npc_cohorts to service_role;
grant select, insert on table public.npc_tick_log to service_role;

revoke all on sequence public.npc_tick_log_id_seq from anon, authenticated;
grant usage, select on sequence public.npc_tick_log_id_seq to service_role;

revoke all on function public.apply_npc_district_update(
  text,
  numeric,
  numeric,
  integer,
  integer,
  integer,
  integer,
  uuid,
  integer,
  integer,
  numeric,
  numeric,
  integer
) from public, anon, authenticated;

grant execute on function public.apply_npc_district_update(
  text,
  numeric,
  numeric,
  integer,
  integer,
  integer,
  integer,
  uuid,
  integer,
  integer,
  numeric,
  numeric,
  integer
) to service_role;

commit;

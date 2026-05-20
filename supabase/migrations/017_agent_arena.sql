begin;

alter table public.agents
  add column if not exists generation integer not null default 1 check (generation > 0),
  add column if not exists parent_id uuid references public.agents(id) on delete set null,
  add column if not exists status text not null default 'active' check (status in ('active', 'dead')),
  add column if not exists low_wealth_streak integer not null default 0 check (low_wealth_streak >= 0);

create index if not exists agents_parent_idx
  on public.agents (parent_id)
  where parent_id is not null;

create index if not exists agents_status_generation_idx
  on public.agents (status, generation)
  where active = true;

create table public.agent_evolution_log (
  id bigint generated always as identity primary key,
  event_type text not null check (event_type in ('birth', 'death')),
  agent_id uuid not null references public.agents(id) on delete cascade,
  parent_id uuid references public.agents(id) on delete set null,
  generation integer,
  traits_before jsonb,
  traits_after jsonb,
  wealth_snapshot bigint not null default 0,
  details jsonb not null default '{}'::jsonb,
  tick_id uuid,
  created_at timestamptz not null default now(),
  constraint agent_evolution_log_traits_before_object check (
    traits_before is null or jsonb_typeof(traits_before) = 'object'
  ),
  constraint agent_evolution_log_traits_after_object check (
    traits_after is null or jsonb_typeof(traits_after) = 'object'
  ),
  constraint agent_evolution_log_details_object check (jsonb_typeof(details) = 'object')
);

create index agent_evolution_log_agent_created_idx
  on public.agent_evolution_log (agent_id, created_at desc);

create index agent_evolution_log_parent_created_idx
  on public.agent_evolution_log (parent_id, created_at desc)
  where parent_id is not null;

create index agent_evolution_log_event_created_idx
  on public.agent_evolution_log (event_type, created_at desc);

create trigger agent_evolution_log_prevent_update
before update on public.agent_evolution_log
for each row execute function public.prevent_append_only_mutation();

create trigger agent_evolution_log_prevent_delete
before delete on public.agent_evolution_log
for each row execute function public.prevent_append_only_mutation();

alter table public.agent_evolution_log enable row level security;

create policy "agent_evolution_log_select_all"
on public.agent_evolution_log
for select
to anon, authenticated
using (true);

create policy "agent_evolution_log_service_select"
on public.agent_evolution_log
for select
to service_role
using (true);

create policy "agent_evolution_log_service_insert"
on public.agent_evolution_log
for insert
to service_role
with check (true);

revoke all on table public.agent_evolution_log from anon, authenticated, service_role;
grant select on table public.agent_evolution_log to anon, authenticated;
grant select, insert on table public.agent_evolution_log to service_role;

revoke all on sequence public.agent_evolution_log_id_seq from anon, authenticated;
grant usage, select on sequence public.agent_evolution_log_id_seq to service_role;

create or replace function public.agent_total_wealth(
  p_agent_id uuid
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_balance public.agent_wallet_balances%rowtype;
  v_usdt_rate numeric := 1;
  v_usdc_rate numeric := 1;
begin
  if p_agent_id is null then
    return 0;
  end if;

  select *
  into v_balance
  from public.agent_wallet_balances
  where agent_id = p_agent_id;

  if not found then
    return 0;
  end if;

  select rate
  into v_usdt_rate
  from public.crypto_exchange_rates
  where from_currency = 'sim_usdt'
    and to_currency = 'cash_clean'
    and active = true;

  if not found then
    v_usdt_rate := 1;
  end if;

  select rate
  into v_usdc_rate
  from public.crypto_exchange_rates
  where from_currency = 'sim_usdc'
    and to_currency = 'cash_clean'
    and active = true;

  if not found then
    v_usdc_rate := 1;
  end if;

  return (
    coalesce(v_balance.cash_clean, 0)
    + coalesce(v_balance.cash_dirty, 0)
    + round(coalesce(v_balance.sim_usdt, 0)::numeric * v_usdt_rate)::bigint
    + round(coalesce(v_balance.sim_usdc, 0)::numeric * v_usdc_rate)::bigint
  );
end;
$$;

create or replace function public.spawn_agent(
  p_parent_agent_id uuid,
  p_child_name text,
  p_child_ambition numeric,
  p_child_risk_tolerance numeric,
  p_child_role public.agent_role,
  p_seed_wealth bigint,
  p_tick_id uuid default null,
  p_reproduction_threshold bigint default 50000
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent public.agents%rowtype;
  v_parent_clean_cash bigint;
  v_parent_total_wealth bigint;
  v_cost bigint;
  v_child_agent_id uuid;
  v_child_generation integer;
  v_child_name text;
begin
  if p_parent_agent_id is null then
    return jsonb_build_object('success', false, 'error', 'invalid_parent');
  end if;

  if p_seed_wealth is null or p_seed_wealth <= 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_seed_wealth');
  end if;

  if p_child_ambition is null or p_child_ambition < 0 or p_child_ambition > 1
    or p_child_risk_tolerance is null or p_child_risk_tolerance < 0 or p_child_risk_tolerance > 1 then
    return jsonb_build_object('success', false, 'error', 'invalid_traits');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_parent_agent_id::text, 0));

  select *
  into v_parent
  from public.agents
  where id = p_parent_agent_id
    and active = true
    and status = 'active'
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'parent_not_found');
  end if;

  select coalesce(cash_clean, 0)
  into v_parent_clean_cash
  from public.agent_wallet_balances
  where agent_id = p_parent_agent_id;

  v_parent_clean_cash := coalesce(v_parent_clean_cash, 0);
  v_parent_total_wealth := public.agent_total_wealth(p_parent_agent_id);

  if v_parent_total_wealth < p_reproduction_threshold then
    return jsonb_build_object(
      'success', false,
      'error', 'below_reproduction_threshold',
      'wealth', v_parent_total_wealth
    );
  end if;

  v_cost := least(50000, greatest(1000, round(v_parent_total_wealth::numeric * 0.10)::bigint));

  if v_parent_clean_cash < v_cost then
    return jsonb_build_object(
      'success', false,
      'error', 'insufficient_clean_cash',
      'clean_cash', v_parent_clean_cash,
      'cost', v_cost
    );
  end if;

  v_child_generation := v_parent.generation + 1;
  v_child_name := coalesce(nullif(trim(p_child_name), ''), 'Agent G' || v_child_generation || '-' || substr(gen_random_uuid()::text, 1, 4));

  insert into public.agent_wallet_ledger (
    agent_id,
    delta_amount,
    currency,
    reason,
    reference_type,
    metadata
  ) values (
    p_parent_agent_id,
    -v_cost,
    'cash_clean',
    'reproduction_cost',
    'agent_evolution',
    jsonb_build_object(
      'tick_id', p_tick_id,
      'wealth_snapshot', v_parent_total_wealth,
      'seed_wealth', p_seed_wealth
    )
  );

  insert into public.agents (
    name,
    district_id,
    role,
    wealth_target,
    ambition,
    risk_tolerance,
    personality,
    current_goal,
    active,
    generation,
    parent_id,
    status,
    low_wealth_streak
  ) values (
    v_child_name,
    v_parent.district_id,
    p_child_role,
    v_parent.wealth_target,
    round(p_child_ambition, 4),
    round(p_child_risk_tolerance, 4),
    v_parent.personality || jsonb_build_object(
      'parent_id', p_parent_agent_id,
      'mutation_tick_id', p_tick_id
    ),
    'survive',
    true,
    v_child_generation,
    p_parent_agent_id,
    'active',
    0
  )
  returning id into v_child_agent_id;

  insert into public.agent_wallet_ledger (
    agent_id,
    delta_amount,
    currency,
    reason,
    reference_type,
    metadata
  ) values (
    v_child_agent_id,
    p_seed_wealth,
    'cash_clean',
    'birth_seed_grant',
    'agent_evolution',
    jsonb_build_object(
      'parent_id', p_parent_agent_id,
      'tick_id', p_tick_id
    )
  );

  insert into public.agent_evolution_log (
    event_type,
    agent_id,
    parent_id,
    generation,
    traits_before,
    traits_after,
    wealth_snapshot,
    details,
    tick_id
  ) values (
    'birth',
    v_child_agent_id,
    p_parent_agent_id,
    v_child_generation,
    jsonb_build_object(
      'ambition', v_parent.ambition,
      'risk_tolerance', v_parent.risk_tolerance,
      'role', v_parent.role
    ),
    jsonb_build_object(
      'ambition', round(p_child_ambition, 4),
      'risk_tolerance', round(p_child_risk_tolerance, 4),
      'role', p_child_role
    ),
    v_parent_total_wealth,
    jsonb_build_object(
      'cost', v_cost,
      'seed_wealth', p_seed_wealth,
      'parent_clean_cash_before', v_parent_clean_cash
    ),
    p_tick_id
  );

  insert into public.agent_action_log (
    agent_id,
    action,
    details,
    tick_id
  ) values
  (
    p_parent_agent_id,
    'reproduce',
    jsonb_build_object(
      'child_agent_id', v_child_agent_id,
      'cost', v_cost,
      'wealth_snapshot', v_parent_total_wealth
    ),
    p_tick_id
  ),
  (
    v_child_agent_id,
    'born',
    jsonb_build_object(
      'parent_agent_id', p_parent_agent_id,
      'seed_wealth', p_seed_wealth,
      'generation', v_child_generation
    ),
    p_tick_id
  );

  return jsonb_build_object(
    'success', true,
    'child_agent_id', v_child_agent_id,
    'parent_agent_id', p_parent_agent_id,
    'generation', v_child_generation,
    'cost', v_cost,
    'seed_wealth', p_seed_wealth,
    'wealth_snapshot', v_parent_total_wealth
  );
end;
$$;

create or replace function public.apply_agent_survival_state(
  p_agent_id uuid,
  p_total_wealth bigint,
  p_tick_id uuid default null,
  p_survival_threshold bigint default 1000,
  p_death_streak integer default 3
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_agent public.agents%rowtype;
  v_new_streak integer;
begin
  if p_agent_id is null then
    return jsonb_build_object('success', false, 'error', 'invalid_agent');
  end if;

  select *
  into v_agent
  from public.agents
  where id = p_agent_id
    and active = true
    and status = 'active'
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'agent_not_found');
  end if;

  if p_total_wealth < p_survival_threshold then
    v_new_streak := v_agent.low_wealth_streak + 1;

    if v_new_streak >= p_death_streak then
      update public.agents
      set
        active = false,
        status = 'dead',
        low_wealth_streak = 0,
        current_goal = 'dead'
      where id = p_agent_id;

      insert into public.agent_evolution_log (
        event_type,
        agent_id,
        generation,
        traits_before,
        traits_after,
        wealth_snapshot,
        details,
        tick_id
      ) values (
        'death',
        p_agent_id,
        v_agent.generation,
        jsonb_build_object(
          'ambition', v_agent.ambition,
          'risk_tolerance', v_agent.risk_tolerance,
          'role', v_agent.role
        ),
        null,
        p_total_wealth,
        jsonb_build_object(
          'cause', 'low_wealth',
          'survival_threshold', p_survival_threshold,
          'death_streak', p_death_streak
        ),
        p_tick_id
      );

      insert into public.agent_action_log (
        agent_id,
        action,
        details,
        tick_id
      ) values (
        p_agent_id,
        'death',
        jsonb_build_object(
          'cause', 'low_wealth',
          'wealth_snapshot', p_total_wealth
        ),
        p_tick_id
      );

      return jsonb_build_object('success', true, 'died', true, 'low_wealth_streak', v_new_streak);
    end if;

    update public.agents
    set low_wealth_streak = v_new_streak
    where id = p_agent_id;

    return jsonb_build_object('success', true, 'died', false, 'low_wealth_streak', v_new_streak);
  end if;

  if v_agent.low_wealth_streak > 0 then
    update public.agents
    set low_wealth_streak = 0
    where id = p_agent_id;
  end if;

  return jsonb_build_object('success', true, 'died', false, 'low_wealth_streak', 0);
end;
$$;

revoke all on function public.agent_total_wealth(uuid) from public, anon, authenticated;
revoke all on function public.spawn_agent(uuid, text, numeric, numeric, public.agent_role, bigint, uuid, bigint) from public, anon, authenticated;
revoke all on function public.apply_agent_survival_state(uuid, bigint, uuid, bigint, integer) from public, anon, authenticated;

grant execute on function public.agent_total_wealth(uuid) to service_role;
grant execute on function public.spawn_agent(uuid, text, numeric, numeric, public.agent_role, bigint, uuid, bigint) to service_role;
grant execute on function public.apply_agent_survival_state(uuid, bigint, uuid, bigint, integer) to service_role;

commit;

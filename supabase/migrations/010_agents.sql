begin;

create type public.agent_role as enum (
  'shopkeeper',
  'smuggler',
  'investor',
  'thief',
  'gig_worker',
  'unemployed'
);

create table public.agents (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  district_id text not null references public.districts(district_id) on delete restrict,
  role public.agent_role not null,
  wealth_target bigint not null default 50000 check (wealth_target > 0),
  ambition numeric(5, 4) not null default 0.5 check (ambition between 0 and 1),
  risk_tolerance numeric(5, 4) not null default 0.5 check (risk_tolerance between 0 and 1),
  personality jsonb not null default '{}'::jsonb,
  current_goal text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agents_personality_object check (jsonb_typeof(personality) = 'object')
);

create index agents_district_role_idx
  on public.agents (district_id, role)
  where active = true;

create trigger agents_set_updated_at
before update on public.agents
for each row execute function public.set_updated_at();

create table public.agent_wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agents(id) on delete cascade,
  delta_amount bigint not null,
  currency text not null default 'cash_clean' check (currency in ('cash_clean', 'cash_dirty')),
  reason text not null,
  reference_type text,
  reference_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint agent_wallet_ledger_has_delta check (delta_amount <> 0),
  constraint agent_wallet_ledger_reason_present check (length(trim(reason)) > 0)
);

create index agent_wallet_ledger_agent_created_idx
  on public.agent_wallet_ledger (agent_id, created_at desc);

create table public.agent_inventory (
  agent_id uuid not null references public.agents(id) on delete cascade,
  item_id text not null references public.inventory_items(item_id) on delete restrict,
  quantity integer not null default 0 check (quantity >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agent_id, item_id)
);

create index agent_inventory_item_idx
  on public.agent_inventory (item_id);

create trigger agent_inventory_set_updated_at
before update on public.agent_inventory
for each row execute function public.set_updated_at();

create table public.agent_action_log (
  id bigint generated always as identity primary key,
  agent_id uuid not null references public.agents(id) on delete cascade,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  tick_id uuid,
  created_at timestamptz not null default now(),
  constraint agent_action_log_details_object check (jsonb_typeof(details) = 'object')
);

create index agent_action_log_agent_created_idx
  on public.agent_action_log (agent_id, created_at desc);

create index agent_action_log_tick_idx
  on public.agent_action_log (tick_id, created_at desc);

create trigger agent_wallet_ledger_prevent_update
before update on public.agent_wallet_ledger
for each row execute function public.prevent_append_only_mutation();

create trigger agent_wallet_ledger_prevent_delete
before delete on public.agent_wallet_ledger
for each row execute function public.prevent_append_only_mutation();

create trigger agent_action_log_prevent_update
before update on public.agent_action_log
for each row execute function public.prevent_append_only_mutation();

create trigger agent_action_log_prevent_delete
before delete on public.agent_action_log
for each row execute function public.prevent_append_only_mutation();

create or replace view public.agent_wallet_balances
with (security_invoker = true)
as
select
  a.id as agent_id,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_clean'), 0)::bigint as cash_clean,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_dirty'), 0)::bigint as cash_dirty,
  max(w.created_at) as last_ledger_at
from public.agents a
left join public.agent_wallet_ledger w on w.agent_id = a.id
group by a.id;

create or replace function public.agent_purchase_item(
  p_agent_id uuid,
  p_item_id text,
  p_quantity integer default 1,
  p_tick_id uuid default null,
  p_reason text default 'agent_purchase'
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item_price bigint;
  v_total_cost bigint;
  v_clean_cash bigint;
begin
  if p_agent_id is null then
    return jsonb_build_object('success', false, 'error', 'invalid_agent');
  end if;

  if p_item_id is null or length(trim(p_item_id)) = 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_item');
  end if;

  if p_quantity is null or p_quantity <= 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_quantity');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_agent_id::text, 0));

  perform 1
  from public.agents
  where id = p_agent_id
    and active = true
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'agent_not_found');
  end if;

  select current_price
  into v_item_price
  from public.market_items
  where item_id = p_item_id
    and active = true
  for update;

  if v_item_price is null then
    return jsonb_build_object('success', false, 'error', 'item_not_found');
  end if;

  perform 1
  from public.inventory_items
  where item_id = p_item_id
    and active = true;

  if not found then
    return jsonb_build_object('success', false, 'error', 'inventory_item_not_found');
  end if;

  v_total_cost := v_item_price * p_quantity::bigint;

  select coalesce(sum(delta_amount), 0)::bigint
  into v_clean_cash
  from public.agent_wallet_ledger
  where agent_id = p_agent_id
    and currency = 'cash_clean';

  if v_clean_cash < v_total_cost then
    return jsonb_build_object(
      'success', false,
      'error', 'insufficient_funds',
      'agent_id', p_agent_id,
      'item_id', p_item_id,
      'quantity', p_quantity,
      'cost', v_total_cost
    );
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
    -v_total_cost,
    'cash_clean',
    p_reason,
    'agent_action',
    jsonb_build_object(
      'item_id', p_item_id,
      'quantity', p_quantity,
      'unit_price', v_item_price,
      'tick_id', p_tick_id
    )
  );

  insert into public.agent_inventory (
    agent_id,
    item_id,
    quantity
  ) values (
    p_agent_id,
    p_item_id,
    p_quantity
  )
  on conflict (agent_id, item_id)
  do update set
    quantity = public.agent_inventory.quantity + excluded.quantity,
    updated_at = now();

  insert into public.agent_action_log (
    agent_id,
    action,
    details,
    tick_id
  ) values (
    p_agent_id,
    p_reason,
    jsonb_build_object(
      'item_id', p_item_id,
      'quantity', p_quantity,
      'unit_price', v_item_price,
      'total_cost', v_total_cost
    ),
    p_tick_id
  );

  return jsonb_build_object(
    'success', true,
    'agent_id', p_agent_id,
    'item_id', p_item_id,
    'quantity', p_quantity,
    'cost', v_total_cost
  );
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

  if p_currency not in ('cash_clean', 'cash_dirty') then
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

create or replace function public.apply_agent_migration(
  p_agent_id uuid,
  p_from_district_id text,
  p_to_district_id text,
  p_tick_id uuid default null
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_agent_id is null or p_to_district_id is null then
    return false;
  end if;

  update public.agents
  set
    district_id = p_to_district_id,
    current_goal = 'migrate'
  where id = p_agent_id
    and district_id = p_from_district_id
    and active = true;

  if not found then
    return false;
  end if;

  insert into public.agent_action_log (
    agent_id,
    action,
    details,
    tick_id
  ) values (
    p_agent_id,
    'migrate',
    jsonb_build_object(
      'from', p_from_district_id,
      'to', p_to_district_id
    ),
    p_tick_id
  );

  return true;
end;
$$;

alter table public.agents enable row level security;
alter table public.agent_wallet_ledger enable row level security;
alter table public.agent_inventory enable row level security;
alter table public.agent_action_log enable row level security;

create policy "agents_select_all"
on public.agents
for select
to anon, authenticated
using (true);

create policy "agent_inventory_select_all"
on public.agent_inventory
for select
to authenticated
using (true);

create policy "agent_wallet_ledger_service_select"
on public.agent_wallet_ledger
for select
to service_role
using (true);

create policy "agent_wallet_ledger_service_insert"
on public.agent_wallet_ledger
for insert
to service_role
with check (true);

create policy "agent_inventory_service_select"
on public.agent_inventory
for select
to service_role
using (true);

create policy "agent_inventory_service_insert"
on public.agent_inventory
for insert
to service_role
with check (true);

create policy "agent_inventory_service_update"
on public.agent_inventory
for update
to service_role
using (true)
with check (true);

create policy "agent_action_log_service_select"
on public.agent_action_log
for select
to service_role
using (true);

create policy "agent_action_log_service_insert"
on public.agent_action_log
for insert
to service_role
with check (true);

revoke all on table public.agents from anon, authenticated, service_role;
revoke all on table public.agent_wallet_ledger from anon, authenticated, service_role;
revoke all on table public.agent_wallet_balances from anon, authenticated, service_role;
revoke all on table public.agent_inventory from anon, authenticated, service_role;
revoke all on table public.agent_action_log from anon, authenticated, service_role;

grant select on table public.agents to anon, authenticated;
grant select on table public.agent_inventory to authenticated;

grant select, insert, update, delete on table public.agents to service_role;
grant select, insert on table public.agent_wallet_ledger to service_role;
grant select on table public.agent_wallet_balances to service_role;
grant select, insert, update on table public.agent_inventory to service_role;
grant select, insert on table public.agent_action_log to service_role;

revoke all on sequence public.agent_action_log_id_seq from anon, authenticated;
grant usage, select on sequence public.agent_action_log_id_seq to service_role;

revoke all on function public.agent_purchase_item(uuid, text, integer, uuid, text) from public, anon, authenticated;
revoke all on function public.apply_agent_cash_delta(uuid, bigint, text, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.apply_agent_migration(uuid, text, text, uuid) from public, anon, authenticated;

grant execute on function public.agent_purchase_item(uuid, text, integer, uuid, text) to service_role;
grant execute on function public.apply_agent_cash_delta(uuid, bigint, text, text, uuid, jsonb) to service_role;
grant execute on function public.apply_agent_migration(uuid, text, text, uuid) to service_role;

with seeded_agents as (
  insert into public.agents (
    name,
    district_id,
    role,
    ambition,
    risk_tolerance,
    wealth_target,
    personality,
    current_goal
  )
  select
    'Agent ' || series.agent_number,
    case
      when series.agent_number <= 20 then 'port'
      when series.agent_number <= 35 then 'downtown'
      else 'vice_beach'
    end,
    case series.agent_number % 6
      when 0 then 'shopkeeper'::public.agent_role
      when 1 then 'smuggler'::public.agent_role
      when 2 then 'investor'::public.agent_role
      when 3 then 'thief'::public.agent_role
      when 4 then 'gig_worker'::public.agent_role
      else 'unemployed'::public.agent_role
    end,
    round((0.30 + random() * 0.50)::numeric, 4),
    round((0.20 + random() * 0.60)::numeric, 4),
    floor(random() * 100000 + 20000)::bigint,
    jsonb_build_object(
      'patience', round((0.20 + random() * 0.70)::numeric, 4),
      'loyalty', round((0.10 + random() * 0.80)::numeric, 4)
    ),
    'survive'
  from generate_series(1, 50) as series(agent_number)
  returning id, role
)
insert into public.agent_wallet_ledger (
  agent_id,
  delta_amount,
  currency,
  reason,
  metadata
)
select
  id,
  case
    when role = 'investor' then 25000
    when role = 'shopkeeper' then 15000
    when role in ('smuggler', 'thief') then 8000
    else 5000
  end,
  'cash_clean',
  'agent_seed_grant',
  jsonb_build_object('source', '010_agents_seed')
from seeded_agents;

commit;

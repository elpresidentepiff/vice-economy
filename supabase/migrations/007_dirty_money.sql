alter table public.wallet_ledger
  drop constraint wallet_ledger_currency_check;

alter table public.wallet_ledger
  add constraint wallet_ledger_currency_check
  check (currency in ('cash_clean', 'cash_dirty'));

alter table public.transactions
  drop constraint transactions_currency_check;

alter table public.transactions
  add constraint transactions_currency_check
  check (currency in ('cash_clean', 'cash_dirty'));

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
    'laundering_complete'
  ));

create or replace view public.wallet_balances
with (security_invoker = true)
as
select
  p.id as player_id,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_clean'), 0)::bigint as cash_clean,
  max(w.created_at) as last_ledger_at,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_dirty'), 0)::bigint as cash_dirty
from public.profiles p
left join public.wallet_ledger w on w.player_id = p.id
group by p.id;

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  business_type text not null,
  daily_capacity bigint not null default 100000 check (daily_capacity > 0),
  laundering_fee_percent numeric(5, 2) not null default 15.0 check (
    laundering_fee_percent >= 0
    and laundering_fee_percent < 100
  ),
  laundering_duration_minutes integer not null default 60 check (laundering_duration_minutes >= 0),
  risk_modifier integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.laundering_jobs (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete restrict,
  amount bigint not null check (amount > 0),
  fee bigint not null check (fee >= 0),
  net_amount bigint generated always as (amount - fee) stored,
  duration_minutes integer not null check (duration_minutes >= 0),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'pending' check (status in ('pending', 'completed', 'failed')),
  risk_score integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint laundering_jobs_net_amount_positive check (net_amount > 0),
  constraint laundering_jobs_completion_status check (
    (status = 'pending' and completed_at is null)
    or (status in ('completed', 'failed') and completed_at is not null)
  )
);

create index businesses_player_idx
  on public.businesses (player_id, active);

create index laundering_jobs_player_created_idx
  on public.laundering_jobs (player_id, created_at desc);

create index laundering_jobs_pending_idx
  on public.laundering_jobs (status, started_at)
  where status = 'pending';

create trigger businesses_set_updated_at
before update on public.businesses
for each row execute function public.set_updated_at();

create trigger laundering_jobs_set_updated_at
before update on public.laundering_jobs
for each row execute function public.set_updated_at();

alter table public.businesses enable row level security;
alter table public.laundering_jobs enable row level security;

create policy "businesses_select_own"
on public.businesses
for select
to authenticated
using ((select auth.uid()) = player_id);

create policy "laundering_jobs_select_own"
on public.laundering_jobs
for select
to authenticated
using ((select auth.uid()) = player_id);

revoke all on table public.businesses from anon, authenticated;
revoke all on table public.laundering_jobs from anon, authenticated;

grant select on table public.businesses to authenticated;
grant select on table public.laundering_jobs to authenticated;

grant select, insert, update on table public.businesses to service_role;
grant select, insert, update on table public.laundering_jobs to service_role;

create or replace function private.start_laundering_impl(
  p_player_id uuid,
  p_business_id uuid,
  p_amount bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_business public.businesses%rowtype;
  v_dirty_cash bigint;
  v_capacity_used bigint;
  v_fee bigint;
  v_job_id uuid;
  v_start_transaction_id uuid;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  if p_player_id is null or p_player_id <> v_auth_uid then
    raise exception 'cannot launder for another player' using errcode = '42501';
  end if;

  if p_business_id is null then
    return jsonb_build_object('success', false, 'error', 'invalid_business');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_amount');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_player_id::text, 0));

  select *
  into v_business
  from public.businesses
  where id = p_business_id
    and player_id = p_player_id
    and active = true
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'business_not_found');
  end if;

  select coalesce(sum(delta_amount), 0)::bigint
  into v_dirty_cash
  from public.wallet_ledger
  where player_id = p_player_id
    and currency = 'cash_dirty';

  if v_dirty_cash < p_amount then
    return jsonb_build_object(
      'success', false,
      'error', 'insufficient_dirty_cash',
      'amount', p_amount
    );
  end if;

  select coalesce(sum(amount), 0)::bigint
  into v_capacity_used
  from public.laundering_jobs
  where business_id = p_business_id
    and status in ('pending', 'completed')
    and started_at >= date_trunc('day', now());

  if v_capacity_used + p_amount > v_business.daily_capacity then
    return jsonb_build_object(
      'success', false,
      'error', 'business_capacity_exceeded',
      'capacity_left', greatest(v_business.daily_capacity - v_capacity_used, 0)
    );
  end if;

  v_fee := round(p_amount * v_business.laundering_fee_percent / 100)::bigint;

  insert into public.transactions (
    player_id,
    transaction_type,
    total_amount,
    currency,
    metadata
  ) values (
    p_player_id,
    'laundering_start',
    -p_amount,
    'cash_dirty',
    jsonb_build_object(
      'business_id', p_business_id,
      'fee', v_fee,
      'fee_percent', v_business.laundering_fee_percent
    )
  )
  returning id into v_start_transaction_id;

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
    'cash_dirty',
    'laundering_start',
    'transaction',
    v_start_transaction_id,
    jsonb_build_object(
      'business_id', p_business_id,
      'fee', v_fee
    )
  );

  insert into public.laundering_jobs (
    player_id,
    business_id,
    amount,
    fee,
    duration_minutes,
    risk_score,
    metadata
  ) values (
    p_player_id,
    p_business_id,
    p_amount,
    v_fee,
    v_business.laundering_duration_minutes,
    greatest(0, least(100, ceil((p_amount::numeric / greatest(v_business.daily_capacity, 1)) * 100)::integer + v_business.risk_modifier)),
    jsonb_build_object('start_transaction_id', v_start_transaction_id)
  )
  returning id into v_job_id;

  return jsonb_build_object(
    'success', true,
    'job_id', v_job_id,
    'business_id', p_business_id,
    'amount', p_amount,
    'fee', v_fee,
    'net_amount', p_amount - v_fee,
    'duration_minutes', v_business.laundering_duration_minutes
  );
end;
$$;

create or replace function public.start_laundering(
  p_player_id uuid,
  p_business_id uuid,
  p_amount bigint
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.start_laundering_impl(p_player_id, p_business_id, p_amount);
$$;

create or replace function public.complete_laundering(
  p_job_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_job public.laundering_jobs%rowtype;
  v_complete_transaction_id uuid;
begin
  if p_job_id is null then
    return jsonb_build_object('success', false, 'error', 'invalid_job');
  end if;

  select *
  into v_job
  from public.laundering_jobs
  where id = p_job_id
    and status = 'pending'
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'job_not_found');
  end if;

  if now() < v_job.started_at + make_interval(mins => v_job.duration_minutes) then
    return jsonb_build_object('success', false, 'error', 'job_not_ready');
  end if;

  insert into public.transactions (
    player_id,
    transaction_type,
    total_amount,
    currency,
    metadata
  ) values (
    v_job.player_id,
    'laundering_complete',
    v_job.net_amount,
    'cash_clean',
    jsonb_build_object(
      'job_id', v_job.id,
      'business_id', v_job.business_id,
      'amount', v_job.amount,
      'fee', v_job.fee
    )
  )
  returning id into v_complete_transaction_id;

  insert into public.wallet_ledger (
    player_id,
    delta_amount,
    currency,
    reason,
    reference_type,
    reference_id,
    metadata
  ) values (
    v_job.player_id,
    v_job.net_amount,
    'cash_clean',
    'laundering_complete',
    'transaction',
    v_complete_transaction_id,
    jsonb_build_object(
      'job_id', v_job.id,
      'business_id', v_job.business_id,
      'amount', v_job.amount,
      'fee', v_job.fee
    )
  );

  update public.laundering_jobs
  set
    status = 'completed',
    completed_at = now(),
    metadata = metadata || jsonb_build_object('complete_transaction_id', v_complete_transaction_id)
  where id = p_job_id;

  return jsonb_build_object(
    'success', true,
    'job_id', p_job_id,
    'clean_added', v_job.net_amount,
    'fee', v_job.fee
  );
end;
$$;

revoke all on function private.start_laundering_impl(uuid, uuid, bigint) from public, anon;
revoke all on function public.start_laundering(uuid, uuid, bigint) from public, anon;
revoke all on function public.complete_laundering(uuid) from public, anon, authenticated;

grant execute on function private.start_laundering_impl(uuid, uuid, bigint) to authenticated;
grant execute on function public.start_laundering(uuid, uuid, bigint) to authenticated;
grant execute on function public.complete_laundering(uuid) to service_role;

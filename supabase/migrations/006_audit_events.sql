create table public.audit_events (
  id bigint generated always as identity primary key,
  operation text not null,
  table_name text not null,
  record_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

create index audit_events_table_record_idx
  on public.audit_events (table_name, record_id, created_at desc);

create table public.system_jobs (
  id uuid primary key default gen_random_uuid(),
  job_type text not null,
  status text not null default 'running' check (status in ('running', 'completed', 'failed')),
  tick_id uuid,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  error text,
  constraint system_jobs_completion_status check (
    (status = 'running' and completed_at is null)
    or (status in ('completed', 'failed') and completed_at is not null)
  )
);

create index system_jobs_type_started_idx
  on public.system_jobs (job_type, started_at desc);

create index system_jobs_status_started_idx
  on public.system_jobs (status, started_at desc);

create or replace function public.audit_insert_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_data jsonb;
  v_record_id uuid;
begin
  v_new_data := to_jsonb(new);
  v_record_id := nullif(v_new_data->>'id', '')::uuid;

  insert into public.audit_events (
    operation,
    table_name,
    record_id,
    old_data,
    new_data
  ) values (
    tg_op,
    tg_table_schema || '.' || tg_table_name,
    v_record_id,
    null,
    v_new_data
  );

  return new;
end;
$$;

create trigger wallet_ledger_audit_insert
after insert on public.wallet_ledger
for each row execute function public.audit_insert_event();

create trigger transactions_audit_insert
after insert on public.transactions
for each row execute function public.audit_insert_event();

create or replace function public.prevent_append_only_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception '% is append-only', tg_table_name;
end;
$$;

create trigger audit_events_prevent_update
before update on public.audit_events
for each row execute function public.prevent_append_only_mutation();

create trigger audit_events_prevent_delete
before delete on public.audit_events
for each row execute function public.prevent_append_only_mutation();

create trigger market_price_history_prevent_update
before update on public.market_price_history
for each row execute function public.prevent_append_only_mutation();

create trigger market_price_history_prevent_delete
before delete on public.market_price_history
for each row execute function public.prevent_append_only_mutation();

alter table public.audit_events enable row level security;
alter table public.system_jobs enable row level security;

create policy "audit_events_service_select"
on public.audit_events
for select
to service_role
using (true);

create policy "audit_events_service_insert"
on public.audit_events
for insert
to service_role
with check (true);

create policy "system_jobs_service_select"
on public.system_jobs
for select
to service_role
using (true);

create policy "system_jobs_service_insert"
on public.system_jobs
for insert
to service_role
with check (true);

create policy "system_jobs_service_update"
on public.system_jobs
for update
to service_role
using (true)
with check (true);

revoke all on table public.audit_events from anon, authenticated, service_role;
revoke all on table public.system_jobs from anon, authenticated, service_role;
revoke update, delete, truncate on table public.market_price_history from service_role;

grant select, insert on table public.audit_events to service_role;
grant select, insert, update on table public.system_jobs to service_role;
grant select, insert on table public.market_price_history to service_role;

revoke all on sequence public.audit_events_id_seq from anon, authenticated;
grant usage, select on sequence public.audit_events_id_seq to service_role;


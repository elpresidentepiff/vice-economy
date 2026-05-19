alter table public.market_items
  add column demand numeric(12, 4) not null default 1 check (demand > 0),
  add column supply numeric(12, 4) not null default 1 check (supply > 0),
  add column last_market_tick_at timestamptz;

create table public.market_price_history (
  id bigint generated always as identity primary key,
  item_id text not null references public.market_items(item_id) on delete restrict,
  old_price bigint not null check (old_price > 0),
  new_price bigint not null check (new_price > 0),
  reason text not null default 'market_tick',
  tick_id uuid not null,
  created_at timestamptz not null default now()
);

create index market_price_history_item_created_idx
  on public.market_price_history (item_id, created_at desc);

create index market_price_history_tick_idx
  on public.market_price_history (tick_id);

alter table public.market_price_history enable row level security;

create policy "market_price_history_service_insert"
on public.market_price_history
for insert
to service_role
with check (true);

create policy "market_price_history_service_select"
on public.market_price_history
for select
to service_role
using (true);

revoke all on table public.market_price_history from anon, authenticated;
grant select, insert on table public.market_price_history to service_role;

revoke all on sequence public.market_price_history_id_seq from anon, authenticated;
grant usage, select on sequence public.market_price_history_id_seq to service_role;


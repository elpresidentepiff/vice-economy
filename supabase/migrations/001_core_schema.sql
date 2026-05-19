create extension if not exists pgcrypto with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.market_items (
  item_id text primary key,
  display_name text not null,
  description text,
  category text not null,
  base_price bigint not null check (base_price > 0),
  current_price bigint not null check (current_price > 0),
  min_price bigint not null check (min_price > 0),
  max_price bigint not null check (max_price >= min_price),
  currency text not null default 'cash_clean' check (currency in ('cash_clean')),
  legal boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint market_items_price_bounds check (
    current_price between min_price and max_price
    and base_price between min_price and max_price
  )
);

create table public.inventory_items (
  item_id text primary key references public.market_items(item_id) on delete restrict,
  display_name text not null,
  description text,
  stackable boolean not null default true,
  legal boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  delta_amount bigint not null,
  currency text not null default 'cash_clean' check (currency in ('cash_clean')),
  reason text not null,
  reference_type text,
  reference_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint wallet_ledger_has_delta check (delta_amount <> 0),
  constraint wallet_ledger_reason_present check (length(trim(reason)) > 0)
);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  transaction_type text not null check (
    transaction_type in ('grant', 'purchase', 'sale', 'adjustment')
  ),
  item_id text references public.market_items(item_id) on delete restrict,
  quantity integer check (quantity is null or quantity > 0),
  unit_price bigint check (unit_price is null or unit_price >= 0),
  total_amount bigint not null default 0,
  currency text not null default 'cash_clean' check (currency in ('cash_clean')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint transactions_has_value check (
    total_amount <> 0 or transaction_type = 'adjustment'
  )
);

alter table public.wallet_ledger
  add constraint wallet_ledger_transaction_id_fkey
  foreign key (reference_id) references public.transactions(id) deferrable initially deferred;

create table public.player_inventory (
  player_id uuid not null references public.profiles(id) on delete cascade,
  item_id text not null references public.inventory_items(item_id) on delete restrict,
  quantity integer not null default 0 check (quantity >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (player_id, item_id)
);

create index wallet_ledger_player_created_idx
  on public.wallet_ledger (player_id, created_at desc);

create index transactions_player_created_idx
  on public.transactions (player_id, created_at desc);

create index player_inventory_player_idx
  on public.player_inventory (player_id);

create view public.wallet_balances
with (security_invoker = true)
as
select
  p.id as player_id,
  coalesce(sum(w.delta_amount) filter (where w.currency = 'cash_clean'), 0)::bigint as cash_clean,
  max(w.created_at) as last_ledger_at
from public.profiles p
left join public.wallet_ledger w on w.player_id = p.id
group by p.id;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger market_items_set_updated_at
before update on public.market_items
for each row execute function public.set_updated_at();

create trigger inventory_items_set_updated_at
before update on public.inventory_items
for each row execute function public.set_updated_at();

create trigger player_inventory_set_updated_at
before update on public.player_inventory
for each row execute function public.set_updated_at();

create or replace function public.prevent_wallet_ledger_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'wallet_ledger is immutable; insert a compensating ledger entry instead';
end;
$$;

create trigger wallet_ledger_prevent_update
before update on public.wallet_ledger
for each row execute function public.prevent_wallet_ledger_mutation();

create trigger wallet_ledger_prevent_delete
before delete on public.wallet_ledger
for each row execute function public.prevent_wallet_ledger_mutation();

create or replace function public.prevent_transaction_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'transactions are immutable; insert a correction transaction instead';
end;
$$;

create trigger transactions_prevent_update
before update on public.transactions
for each row execute function public.prevent_transaction_mutation();

create trigger transactions_prevent_delete
before delete on public.transactions
for each row execute function public.prevent_transaction_mutation();

alter table public.profiles enable row level security;
alter table public.wallet_ledger enable row level security;
alter table public.market_items enable row level security;
alter table public.inventory_items enable row level security;
alter table public.player_inventory enable row level security;
alter table public.transactions enable row level security;

create policy "profiles_select_own"
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);

create policy "profiles_insert_own"
on public.profiles
for insert
to authenticated
with check ((select auth.uid()) = id);

create policy "profiles_update_own_non_money_fields"
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy "wallet_ledger_select_own"
on public.wallet_ledger
for select
to authenticated
using ((select auth.uid()) = player_id);

create policy "market_items_select_active"
on public.market_items
for select
to authenticated
using (active = true);

create policy "inventory_items_select_active"
on public.inventory_items
for select
to authenticated
using (active = true);

create policy "player_inventory_select_own"
on public.player_inventory
for select
to authenticated
using ((select auth.uid()) = player_id);

create policy "transactions_select_own"
on public.transactions
for select
to authenticated
using ((select auth.uid()) = player_id);

revoke all on table public.profiles from anon, authenticated;
revoke all on table public.wallet_ledger from anon, authenticated;
revoke all on table public.market_items from anon, authenticated;
revoke all on table public.inventory_items from anon, authenticated;
revoke all on table public.player_inventory from anon, authenticated;
revoke all on table public.transactions from anon, authenticated;
revoke all on table public.wallet_balances from anon, authenticated;

grant select, insert on table public.profiles to authenticated;
grant update (display_name) on table public.profiles to authenticated;
grant select on table public.wallet_ledger to authenticated;
grant select on table public.market_items to authenticated;
grant select on table public.inventory_items to authenticated;
grant select on table public.player_inventory to authenticated;
grant select on table public.transactions to authenticated;
grant select on table public.wallet_balances to authenticated;

grant select, insert, update on table public.profiles to service_role;
grant select, insert on table public.wallet_ledger to service_role;
grant select, insert, update on table public.market_items to service_role;
grant select, insert, update on table public.inventory_items to service_role;
grant select, insert, update on table public.player_inventory to service_role;
grant select, insert on table public.transactions to service_role;
grant select on table public.wallet_balances to service_role;

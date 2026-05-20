begin;

create policy "market_items_select_active_anon"
on public.market_items
for select
to anon
using (active = true);

grant select on table public.market_items to anon;

commit;

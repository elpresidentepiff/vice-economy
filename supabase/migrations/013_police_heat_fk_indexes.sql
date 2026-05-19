begin;

create index if not exists player_heat_district_idx
  on public.player_heat (district_id);

create index if not exists bribe_events_transaction_idx
  on public.bribe_events (transaction_id);

commit;

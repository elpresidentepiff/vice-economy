create or replace function public.apply_market_price_update(
  p_item_id text,
  p_expected_old_price bigint,
  p_new_price bigint,
  p_tick_id uuid,
  p_reason text default 'market_tick'
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.market_items
  set
    current_price = p_new_price,
    last_market_tick_at = now()
  where item_id = p_item_id
    and current_price = p_expected_old_price;

  if not found then
    return false;
  end if;

  insert into public.market_price_history (
    item_id,
    old_price,
    new_price,
    reason,
    tick_id
  ) values (
    p_item_id,
    p_expected_old_price,
    p_new_price,
    p_reason,
    p_tick_id
  );

  return true;
end;
$$;

revoke all on function public.apply_market_price_update(text, bigint, bigint, uuid, text) from public, anon, authenticated;
grant execute on function public.apply_market_price_update(text, bigint, bigint, uuid, text) to service_role;


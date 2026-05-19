create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function private.purchase_item_impl(
  p_player_id uuid,
  p_item_id text,
  p_quantity integer default 1
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_uid uuid;
  v_item_price bigint;
  v_total_cost bigint;
  v_clean_cash bigint;
  v_transaction_id uuid;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  if p_player_id is null or p_player_id <> v_auth_uid then
    raise exception 'cannot purchase for another player' using errcode = '42501';
  end if;

  if p_item_id is null or length(trim(p_item_id)) = 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_item');
  end if;

  if p_quantity is null or p_quantity <= 0 then
    return jsonb_build_object('success', false, 'error', 'invalid_quantity');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_player_id::text, 0));

  perform 1
  from public.profiles
  where id = p_player_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'wallet_not_found');
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
  from public.wallet_ledger
  where player_id = p_player_id
    and currency = 'cash_clean';

  if v_clean_cash < v_total_cost then
    return jsonb_build_object(
      'success', false,
      'error', 'insufficient_funds',
      'item_id', p_item_id,
      'quantity', p_quantity,
      'cost', v_total_cost
    );
  end if;

  insert into public.transactions (
    player_id,
    transaction_type,
    item_id,
    quantity,
    unit_price,
    total_amount,
    currency,
    metadata
  ) values (
    p_player_id,
    'purchase',
    p_item_id,
    p_quantity,
    v_item_price,
    -v_total_cost,
    'cash_clean',
    jsonb_build_object('source', 'purchase_item')
  )
  returning id into v_transaction_id;

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
    -v_total_cost,
    'cash_clean',
    'market_purchase',
    'transaction',
    v_transaction_id,
    jsonb_build_object(
      'item_id', p_item_id,
      'quantity', p_quantity,
      'unit_price', v_item_price
    )
  );

  insert into public.player_inventory (
    player_id,
    item_id,
    quantity
  ) values (
    p_player_id,
    p_item_id,
    p_quantity
  )
  on conflict (player_id, item_id)
  do update set
    quantity = public.player_inventory.quantity + excluded.quantity,
    updated_at = now();

  return jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'item_id', p_item_id,
    'quantity', p_quantity,
    'cost', v_total_cost
  );
end;
$$;

create or replace function public.purchase_item(
  p_player_id uuid,
  p_item_id text,
  p_quantity integer default 1
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.purchase_item_impl(p_player_id, p_item_id, p_quantity);
$$;

revoke all on function private.purchase_item_impl(uuid, text, integer) from public, anon;
revoke all on function public.purchase_item(uuid, text, integer) from public, anon;

grant execute on function private.purchase_item_impl(uuid, text, integer) to authenticated;
grant execute on function public.purchase_item(uuid, text, integer) to authenticated;


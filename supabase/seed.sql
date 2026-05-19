insert into public.market_items (
  item_id,
  display_name,
  description,
  category,
  base_price,
  current_price,
  min_price,
  max_price,
  demand,
  supply,
  currency,
  legal,
  active
) values
  (
    'water_bottle',
    'Water Bottle',
    'Basic hydration. Cheap, legal, always useful.',
    'consumable',
    250,
    250,
    100,
    750,
    3,
    2,
    'cash_clean',
    true,
    true
  ),
  (
    'street_taco',
    'Street Taco',
    'A quick meal from a legal vendor.',
    'consumable',
    500,
    500,
    250,
    1500,
    4,
    5,
    'cash_clean',
    true,
    true
  ),
  (
    'burner_phone',
    'Burner Phone',
    'Disposable phone sold through gray-market channels.',
    'equipment',
    3500,
    3500,
    2000,
    9000,
    2,
    1,
    'cash_clean',
    true,
    true
  )
on conflict (item_id) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  category = excluded.category,
  base_price = excluded.base_price,
  current_price = excluded.current_price,
  min_price = excluded.min_price,
  max_price = excluded.max_price,
  demand = excluded.demand,
  supply = excluded.supply,
  currency = excluded.currency,
  legal = excluded.legal,
  active = excluded.active,
  updated_at = now();

insert into public.inventory_items (
  item_id,
  display_name,
  description,
  stackable,
  legal,
  active
) values
  (
    'water_bottle',
    'Water Bottle',
    'Basic hydration. Cheap, legal, always useful.',
    true,
    true,
    true
  ),
  (
    'street_taco',
    'Street Taco',
    'A quick meal from a legal vendor.',
    true,
    true,
    true
  ),
  (
    'burner_phone',
    'Burner Phone',
    'Disposable phone sold through gray-market channels.',
    true,
    true,
    true
  )
on conflict (item_id) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  stackable = excluded.stackable,
  legal = excluded.legal,
  active = excluded.active,
  updated_at = now();

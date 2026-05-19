import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../db/supabaseAdmin.js";
import { loadConfig } from "../config.js";

type MarketItem = {
  item_id: string;
  base_price: number;
  current_price: number;
  min_price: number;
  max_price: number;
  demand: number;
  supply: number;
};

type MarketTickUpdate = {
  itemId: string;
  oldPrice: number;
  newPrice: number;
};

export type MarketTickResult = {
  tickId: string;
  updated: number;
  skipped: number;
  updates: MarketTickUpdate[];
};

const config = loadConfig();

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

export function calculateNextPrice(item: MarketItem, damping = config.marketDamping): number {
  const demand = Math.max(Number(item.demand), 1);
  const supply = Math.max(Number(item.supply), 1);
  const targetPrice = Number(item.base_price) * (demand / supply);
  const dampedPrice = Number(item.current_price) + (targetPrice - Number(item.current_price)) * damping;
  const boundedPrice = clamp(dampedPrice, Number(item.min_price), Number(item.max_price));

  return Math.max(1, Math.round(boundedPrice));
}

async function writeMarketUpdate(item: MarketItem, newPrice: number, tickId: string): Promise<void> {
  const { data, error } = await supabaseAdmin.rpc("apply_market_price_update", {
    p_item_id: item.item_id,
    p_expected_old_price: item.current_price,
    p_new_price: newPrice,
    p_tick_id: tickId,
    p_reason: "market_tick",
  });

  if (error) {
    throw new Error(`Failed to update market item ${item.item_id}: ${error.message}`);
  }

  if (data !== true) {
    throw new Error(`Skipped market item ${item.item_id}: current price changed before update`);
  }
}

export async function marketTick(): Promise<MarketTickResult> {
  const tickId = randomUUID();
  const { data, error } = await supabaseAdmin
    .from("market_items")
    .select("item_id, base_price, current_price, min_price, max_price, demand, supply")
    .eq("active", true)
    .order("item_id", { ascending: true });

  if (error) {
    throw new Error(`Failed to fetch market items: ${error.message}`);
  }

  const items = (data ?? []) as MarketItem[];
  const updates: MarketTickUpdate[] = [];

  for (const item of items) {
    const newPrice = calculateNextPrice(item);
    if (newPrice === Number(item.current_price)) {
      continue;
    }

    await writeMarketUpdate(item, newPrice, tickId);
    updates.push({
      itemId: item.item_id,
      oldPrice: Number(item.current_price),
      newPrice,
    });
  }

  return {
    tickId,
    updated: updates.length,
    skipped: items.length - updates.length,
    updates,
  };
}

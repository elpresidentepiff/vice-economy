import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../db/supabaseAdmin.js";

type District = {
  district_id: string;
  demand_multiplier: number;
  prosperity_index: number;
  security_level: number;
  heat_level: number;
  supply_disruption: number;
  crime_pressure: number;
};

type MarketItem = {
  item_id: string;
  base_price: number;
  current_price: number;
  min_price: number;
  max_price: number;
};

type WorldEvent = {
  id: string;
  affected_districts: string[];
  price_modifiers: Record<string, unknown>;
};

type DistrictPrice = {
  district_id: string;
  item_id: string;
  current_price: number;
};

type DistrictTickUpdate = {
  districtId: string;
  itemId: string;
  oldPrice: number;
  newPrice: number;
};

export type DistrictTickResult = {
  tickId: string;
  updated: number;
  skipped: number;
  updates: DistrictTickUpdate[];
};

const DISTRICT_DAMPING = 0.1;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function priceKey(districtId: string, itemId: string): string {
  return `${districtId}:${itemId}`;
}

function worldEventMultiplier(events: WorldEvent[], districtId: string, itemId: string): number {
  return events.reduce((multiplier, event) => {
    if (!event.affected_districts.includes(districtId)) {
      return multiplier;
    }

    const modifier = event.price_modifiers[itemId];
    if (typeof modifier !== "number" || !Number.isFinite(modifier) || modifier <= 0) {
      return multiplier;
    }

    return multiplier * modifier;
  }, 1);
}

export function calculateDistrictPriceTarget(
  item: MarketItem,
  district: District,
  events: WorldEvent[],
): number {
  const prosperityFactor = 0.8 + (Number(district.prosperity_index) / 100) * 0.4;
  const securityRiskFactor = 1 + ((50 - Number(district.security_level)) / 100) * 0.1;
  const heatFactor = 1 + (Number(district.heat_level) / 100) * 0.15;
  const crimeFactor = 1 + (Number(district.crime_pressure) / 100) * 0.1;
  const eventFactor = worldEventMultiplier(events, district.district_id, item.item_id);

  const target =
    Number(item.current_price) *
    Number(district.demand_multiplier) *
    Number(district.supply_disruption) *
    prosperityFactor *
    securityRiskFactor *
    heatFactor *
    crimeFactor *
    eventFactor;

  return Math.max(1, Math.round(clamp(target, Number(item.min_price), Number(item.max_price))));
}

function calculateDampedPrice(oldPrice: number, targetPrice: number): number {
  return Math.max(1, Math.round(oldPrice + (targetPrice - oldPrice) * DISTRICT_DAMPING));
}

async function writeDistrictUpdate(update: DistrictTickUpdate, tickId: string): Promise<void> {
  const { data, error } = await supabaseAdmin.rpc("apply_district_price_update", {
    p_district_id: update.districtId,
    p_item_id: update.itemId,
    p_expected_old_price: update.oldPrice,
    p_new_price: update.newPrice,
    p_tick_id: tickId,
    p_reason: "district_tick",
  });

  if (error) {
    throw new Error(
      `Failed to update district price ${update.districtId}/${update.itemId}: ${error.message}`,
    );
  }

  if (data !== true) {
    throw new Error(
      `Skipped district price ${update.districtId}/${update.itemId}: current price changed before update`,
    );
  }
}

export async function districtTick(): Promise<DistrictTickResult> {
  const tickId = randomUUID();
  const now = new Date().toISOString();

  const { data: districtData, error: districtError } = await supabaseAdmin
    .from("districts")
    .select(
      "district_id, demand_multiplier, prosperity_index, security_level, heat_level, supply_disruption, crime_pressure",
    )
    .order("district_id", { ascending: true });

  if (districtError) {
    throw new Error(`Failed to fetch districts: ${districtError.message}`);
  }

  const { data: itemData, error: itemError } = await supabaseAdmin
    .from("market_items")
    .select("item_id, base_price, current_price, min_price, max_price")
    .eq("active", true)
    .order("item_id", { ascending: true });

  if (itemError) {
    throw new Error(`Failed to fetch market items: ${itemError.message}`);
  }

  const { data: eventData, error: eventError } = await supabaseAdmin
    .from("world_events")
    .select("id, affected_districts, price_modifiers")
    .eq("active", true)
    .lte("start_time", now)
    .gt("end_time", now);

  if (eventError) {
    throw new Error(`Failed to fetch world events: ${eventError.message}`);
  }

  const { data: priceData, error: priceError } = await supabaseAdmin
    .from("district_prices")
    .select("district_id, item_id, current_price");

  if (priceError) {
    throw new Error(`Failed to fetch district prices: ${priceError.message}`);
  }

  const districts = (districtData ?? []) as District[];
  const items = (itemData ?? []) as MarketItem[];
  const events = (eventData ?? []) as WorldEvent[];
  const existingPrices = new Map(
    ((priceData ?? []) as DistrictPrice[]).map((price) => [
      priceKey(price.district_id, price.item_id),
      Number(price.current_price),
    ]),
  );
  const updates: DistrictTickUpdate[] = [];
  const possibleUpdates = districts.length * items.length;

  for (const district of districts) {
    for (const item of items) {
      const oldPrice =
        existingPrices.get(priceKey(district.district_id, item.item_id)) ?? Number(item.current_price);
      const targetPrice = calculateDistrictPriceTarget(item, district, events);
      const newPrice = calculateDampedPrice(oldPrice, targetPrice);

      if (newPrice === oldPrice) {
        continue;
      }

      const update = {
        districtId: district.district_id,
        itemId: item.item_id,
        oldPrice,
        newPrice,
      };

      await writeDistrictUpdate(update, tickId);
      updates.push(update);
    }
  }

  return {
    tickId,
    updated: updates.length,
    skipped: possibleUpdates - updates.length,
    updates,
  };
}

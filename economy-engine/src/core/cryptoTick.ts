import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../db/supabaseAdmin.js";

type CryptoExchangeRate = {
  id: string;
  from_currency: string;
  to_currency: string;
  rate: number | string;
  min_rate: number | string;
  max_rate: number | string;
  spread_bps: number;
};

type CryptoRateUpdate = {
  rateId: string;
  pair: string;
  oldRate: number;
  newRate: number;
};

export type CryptoTickResult = {
  tickId: string;
  updated: number;
  skipped: number;
  updates: CryptoRateUpdate[];
};

const MAX_RANDOM_WALK = 0.005;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function nextRate(rate: CryptoExchangeRate): number {
  const current = Number(rate.rate);
  const min = Number(rate.min_rate);
  const max = Number(rate.max_rate);
  const movement = (Math.random() * 2 - 1) * MAX_RANDOM_WALK;

  return Number(clamp(current * (1 + movement), min, max).toFixed(8));
}

async function writeRateUpdate(rate: CryptoExchangeRate, newRate: number): Promise<boolean> {
  const { data, error } = await supabaseAdmin.rpc("apply_crypto_rate_update", {
    p_rate_id: rate.id,
    p_expected_rate: Number(rate.rate),
    p_new_rate: newRate,
  });

  if (error) {
    throw new Error(`Failed to update crypto rate ${rate.id}: ${error.message}`);
  }

  return data === true;
}

export async function cryptoTick(): Promise<CryptoTickResult> {
  const tickId = randomUUID();
  const { data, error } = await supabaseAdmin
    .from("crypto_exchange_rates")
    .select("id, from_currency, to_currency, rate, min_rate, max_rate, spread_bps")
    .eq("active", true)
    .order("from_currency", { ascending: true })
    .order("to_currency", { ascending: true });

  if (error) {
    throw new Error(`Failed to fetch crypto exchange rates: ${error.message}`);
  }

  const rates = (data ?? []) as CryptoExchangeRate[];
  const updates: CryptoRateUpdate[] = [];
  let skipped = 0;

  for (const rate of rates) {
    const oldRate = Number(rate.rate);
    const newRate = nextRate(rate);

    if (newRate === oldRate) {
      skipped += 1;
      continue;
    }

    const updated = await writeRateUpdate(rate, newRate);
    if (!updated) {
      skipped += 1;
      continue;
    }

    updates.push({
      rateId: rate.id,
      pair: `${rate.from_currency}/${rate.to_currency}`,
      oldRate,
      newRate,
    });
  }

  return {
    tickId,
    updated: updates.length,
    skipped,
    updates,
  };
}

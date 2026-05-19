import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../db/supabaseAdmin.js";

type CohortType = "working_class" | "wealthy" | "tourist" | "criminal";

type Cohort = {
  id: string;
  district_id: string;
  cohort_type: CohortType;
  population: number;
  wealth_level: number;
  fear_level: number;
  demand_profile: Record<string, unknown>;
};

type District = {
  district_id: string;
  demand_multiplier: number | string;
  crime_pressure: number;
  heat_level: number;
};

type WorldEvent = {
  id: string;
  event_type: string;
  affected_districts: string[];
};

type NpcDistrictUpdate = {
  districtId: string;
  oldDemandMultiplier: number;
  newDemandMultiplier: number;
  oldCrimePressure: number;
  newCrimePressure: number;
  oldHeatLevel: number;
  newHeatLevel: number;
  cohortCount: number;
  totalPopulation: number;
  avgFear: number;
  avgWealth: number;
  eventFearDelta: number;
};

export type NpcTickResult = {
  tickId: string;
  updated: number;
  skipped: number;
  updates: NpcDistrictUpdate[];
};

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function roundDecimal(value: number, precision = 4): number {
  const factor = 10 ** precision;
  return Math.round(value * factor) / factor;
}

function averageDemandProfileWeight(cohorts: Cohort[], totalPopulation: number): number {
  if (totalPopulation <= 0) {
    return 1;
  }

  let weightedTotal = 0;
  let weightCount = 0;

  for (const cohort of cohorts) {
    const values = Object.values(cohort.demand_profile)
      .filter((value): value is number => typeof value === "number" && Number.isFinite(value));

    if (values.length === 0) {
      weightedTotal += cohort.population;
      weightCount += cohort.population;
      continue;
    }

    const cohortAverage = values.reduce((sum, value) => sum + value, 0) / values.length;
    weightedTotal += cohortAverage * cohort.population;
    weightCount += cohort.population;
  }

  return weightCount > 0 ? weightedTotal / weightCount : 1;
}

function eventFearDelta(events: WorldEvent[], districtId: string): number {
  return events.reduce((delta, event) => {
    if (!event.affected_districts.includes(districtId)) {
      return delta;
    }

    switch (event.event_type) {
      case "gang_war":
        return delta + 20;
      case "storm":
        return delta + 10;
      case "festival":
        return delta - 10;
      default:
        return delta;
    }
  }, 0);
}

function calculateDistrictUpdate(
  district: District,
  cohorts: Cohort[],
  events: WorldEvent[],
): NpcDistrictUpdate | null {
  const totalPopulation = cohorts.reduce((sum, cohort) => sum + Number(cohort.population), 0);
  if (totalPopulation <= 0) {
    return null;
  }

  const weightedFear = cohorts.reduce(
    (sum, cohort) => sum + Number(cohort.fear_level) * Number(cohort.population),
    0,
  );
  const weightedWealth = cohorts.reduce(
    (sum, cohort) => sum + Number(cohort.wealth_level) * Number(cohort.population),
    0,
  );
  const avgFear = weightedFear / totalPopulation;
  const avgWealth = weightedWealth / totalPopulation;
  const profileWeight = averageDemandProfileWeight(cohorts, totalPopulation);
  const fearDelta = eventFearDelta(events, district.district_id);

  const demandTarget = profileWeight * (0.85 + avgFear / 250 + avgWealth / 300 + fearDelta / 150);
  const newDemandMultiplier = roundDecimal(clamp(demandTarget, 0.5, 2.0));

  const criminalPopulation = cohorts
    .filter((cohort) => cohort.cohort_type === "criminal")
    .reduce((sum, cohort) => sum + Number(cohort.population), 0);
  const crimeRatio = criminalPopulation / totalPopulation;
  const newCrimePressure = Math.round(clamp(crimeRatio * 100 + avgFear / 2 + Math.max(fearDelta, 0) / 2, 0, 100));
  const newHeatLevel = Math.round(clamp(avgFear / 2 + Math.max(fearDelta, 0), 0, 100));

  return {
    districtId: district.district_id,
    oldDemandMultiplier: Number(district.demand_multiplier),
    newDemandMultiplier,
    oldCrimePressure: Number(district.crime_pressure),
    newCrimePressure,
    oldHeatLevel: Number(district.heat_level),
    newHeatLevel,
    cohortCount: cohorts.length,
    totalPopulation,
    avgFear: roundDecimal(avgFear, 2),
    avgWealth: roundDecimal(avgWealth, 2),
    eventFearDelta: fearDelta,
  };
}

async function writeNpcDistrictUpdate(update: NpcDistrictUpdate, tickId: string): Promise<void> {
  const { data, error } = await supabaseAdmin.rpc("apply_npc_district_update", {
    p_district_id: update.districtId,
    p_expected_demand_multiplier: update.oldDemandMultiplier,
    p_new_demand_multiplier: update.newDemandMultiplier,
    p_expected_crime_pressure: update.oldCrimePressure,
    p_new_crime_pressure: update.newCrimePressure,
    p_expected_heat_level: update.oldHeatLevel,
    p_new_heat_level: update.newHeatLevel,
    p_tick_id: tickId,
    p_cohort_count: update.cohortCount,
    p_total_population: update.totalPopulation,
    p_avg_fear: update.avgFear,
    p_avg_wealth: update.avgWealth,
    p_event_fear_delta: update.eventFearDelta,
  });

  if (error) {
    throw new Error(`Failed to update NPC district ${update.districtId}: ${error.message}`);
  }

  if (data !== true) {
    throw new Error(`Skipped NPC district ${update.districtId}: district changed before update`);
  }
}

export async function npcTick(): Promise<NpcTickResult> {
  const tickId = randomUUID();
  const now = new Date().toISOString();

  const { data: cohortData, error: cohortError } = await supabaseAdmin
    .from("npc_cohorts")
    .select("id, district_id, cohort_type, population, wealth_level, fear_level, demand_profile")
    .order("district_id", { ascending: true });

  if (cohortError) {
    throw new Error(`Failed to fetch NPC cohorts: ${cohortError.message}`);
  }

  const { data: districtData, error: districtError } = await supabaseAdmin
    .from("districts")
    .select("district_id, demand_multiplier, crime_pressure, heat_level")
    .order("district_id", { ascending: true });

  if (districtError) {
    throw new Error(`Failed to fetch districts: ${districtError.message}`);
  }

  const { data: eventData, error: eventError } = await supabaseAdmin
    .from("world_events")
    .select("id, event_type, affected_districts")
    .eq("active", true)
    .lte("start_time", now)
    .gt("end_time", now);

  if (eventError) {
    throw new Error(`Failed to fetch world events: ${eventError.message}`);
  }

  const cohorts = (cohortData ?? []) as Cohort[];
  const districts = (districtData ?? []) as District[];
  const events = (eventData ?? []) as WorldEvent[];
  const cohortsByDistrict = new Map<string, Cohort[]>();

  for (const cohort of cohorts) {
    const existing = cohortsByDistrict.get(cohort.district_id) ?? [];
    existing.push(cohort);
    cohortsByDistrict.set(cohort.district_id, existing);
  }

  const updates: NpcDistrictUpdate[] = [];

  for (const district of districts) {
    const districtCohorts = cohortsByDistrict.get(district.district_id) ?? [];
    const update = calculateDistrictUpdate(district, districtCohorts, events);

    if (!update) {
      continue;
    }

    if (
      Math.abs(update.newDemandMultiplier - update.oldDemandMultiplier) < 0.0001 &&
      update.newCrimePressure === update.oldCrimePressure &&
      update.newHeatLevel === update.oldHeatLevel
    ) {
      continue;
    }

    await writeNpcDistrictUpdate(update, tickId);
    updates.push(update);
  }

  return {
    tickId,
    updated: updates.length,
    skipped: districts.length - updates.length,
    updates,
  };
}

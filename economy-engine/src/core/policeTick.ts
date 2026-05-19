import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../db/supabaseAdmin.js";

type District = {
  district_id: string;
  heat_level: number;
  crime_pressure: number;
  security_level: number;
  police_presence: number;
  checkpoint_level: number;
  supply_disruption: number | string;
};

type PoliceUpdate = {
  districtId: string;
  oldPolicePresence: number;
  newPolicePresence: number;
  oldCheckpointLevel: number;
  newCheckpointLevel: number;
  oldSupplyDisruption: number;
  newSupplyDisruption: number;
  incidentType: string | null;
  severity: number;
};

export type PoliceTickResult = {
  tickId: string;
  updated: number;
  skipped: number;
  updates: PoliceUpdate[];
};

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function dampen(current: number, target: number, factor: number): number {
  return Math.round(current + (target - current) * factor);
}

function calculatePolicePresence(district: District): number {
  const rawPresence = district.heat_level * 0.45 + district.crime_pressure * 0.55;
  const securityDampen = 1 - district.security_level / 250;
  return clamp(dampen(district.police_presence, rawPresence * securityDampen, 0.35), 0, 100);
}

function calculateCheckpointLevel(district: District, policePresence: number): number {
  const target = policePresence * 0.65 + district.heat_level * 0.25;
  return clamp(dampen(district.checkpoint_level, target, 0.4), 0, 100);
}

function calculateSupplyDisruption(checkpointLevel: number): number {
  return Number((1 + (checkpointLevel / 100) * 0.3).toFixed(4));
}

function incidentFor(
  oldPresence: number,
  newPresence: number,
  oldCheckpoint: number,
  newCheckpoint: number,
): { incidentType: string | null; severity: number } {
  const presenceDelta = newPresence - oldPresence;
  const checkpointDelta = newCheckpoint - oldCheckpoint;
  const severity = Math.max(Math.abs(presenceDelta), Math.abs(checkpointDelta));

  if (severity < 5) {
    return { incidentType: null, severity: 0 };
  }

  if (checkpointDelta >= 5 && Math.abs(checkpointDelta) >= Math.abs(presenceDelta)) {
    return { incidentType: "checkpoint", severity };
  }

  return {
    incidentType: presenceDelta >= 0 ? "patrol_increase" : "patrol_decrease",
    severity,
  };
}

async function writePoliceUpdate(
  district: District,
  update: PoliceUpdate,
  tickId: string,
): Promise<boolean> {
  const { data, error } = await supabaseAdmin.rpc("apply_police_district_update", {
    p_district_id: district.district_id,
    p_expected_police_presence: update.oldPolicePresence,
    p_new_police_presence: update.newPolicePresence,
    p_expected_checkpoint_level: update.oldCheckpointLevel,
    p_new_checkpoint_level: update.newCheckpointLevel,
    p_expected_supply_disruption: update.oldSupplyDisruption,
    p_new_supply_disruption: update.newSupplyDisruption,
    p_tick_id: tickId,
    p_incident_type: update.incidentType,
    p_severity: update.severity,
    p_details: {
      heat_level: district.heat_level,
      crime_pressure: district.crime_pressure,
      security_level: district.security_level,
      supply_disruption_source: "checkpoint_level",
    },
  });

  if (error) {
    throw new Error(`Failed to update police state for ${district.district_id}: ${error.message}`);
  }

  return data === true;
}

export async function policeTick(): Promise<PoliceTickResult> {
  const tickId = randomUUID();
  const { data, error } = await supabaseAdmin
    .from("districts")
    .select(
      "district_id, heat_level, crime_pressure, security_level, police_presence, checkpoint_level, supply_disruption",
    )
    .order("district_id", { ascending: true });

  if (error) {
    throw new Error(`Failed to fetch districts for police tick: ${error.message}`);
  }

  const districts = (data ?? []) as District[];
  const updates: PoliceUpdate[] = [];
  let skipped = 0;

  for (const district of districts) {
    const oldPolicePresence = district.police_presence;
    const oldCheckpointLevel = district.checkpoint_level;
    const oldSupplyDisruption = Number(district.supply_disruption);
    const newPolicePresence = calculatePolicePresence(district);
    const newCheckpointLevel = calculateCheckpointLevel(district, newPolicePresence);
    const newSupplyDisruption = calculateSupplyDisruption(newCheckpointLevel);
    const { incidentType, severity } = incidentFor(
      oldPolicePresence,
      newPolicePresence,
      oldCheckpointLevel,
      newCheckpointLevel,
    );

    if (
      newPolicePresence === oldPolicePresence &&
      newCheckpointLevel === oldCheckpointLevel &&
      newSupplyDisruption === oldSupplyDisruption
    ) {
      skipped += 1;
      continue;
    }

    const update: PoliceUpdate = {
      districtId: district.district_id,
      oldPolicePresence,
      newPolicePresence,
      oldCheckpointLevel,
      newCheckpointLevel,
      oldSupplyDisruption,
      newSupplyDisruption,
      incidentType,
      severity,
    };

    const written = await writePoliceUpdate(district, update, tickId);
    if (!written) {
      skipped += 1;
      continue;
    }

    updates.push(update);
  }

  return {
    tickId,
    updated: updates.length,
    skipped,
    updates,
  };
}

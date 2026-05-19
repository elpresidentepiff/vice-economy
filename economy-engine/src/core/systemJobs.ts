import { supabaseAdmin } from "../db/supabaseAdmin.js";

export type SystemJob = {
  id: string;
  job_type: string;
  status: "running" | "completed" | "failed";
  tick_id: string | null;
  metadata: Record<string, unknown>;
};

export async function startSystemJob(
  jobType: string,
  metadata: Record<string, unknown> = {},
): Promise<SystemJob> {
  const { data, error } = await supabaseAdmin
    .from("system_jobs")
    .insert({
      job_type: jobType,
      metadata,
    })
    .select("id, job_type, status, tick_id, metadata")
    .single();

  if (error) {
    throw new Error(`Failed to start system job ${jobType}: ${error.message}`);
  }

  return data as SystemJob;
}

export async function completeSystemJob(
  jobId: string,
  tickId: string | null,
  metadata: Record<string, unknown> = {},
): Promise<void> {
  const { error } = await supabaseAdmin
    .from("system_jobs")
    .update({
      status: "completed",
      tick_id: tickId,
      completed_at: new Date().toISOString(),
      metadata,
      error: null,
    })
    .eq("id", jobId);

  if (error) {
    throw new Error(`Failed to complete system job ${jobId}: ${error.message}`);
  }
}

export async function failSystemJob(
  jobId: string,
  message: string,
  metadata: Record<string, unknown> = {},
): Promise<void> {
  const { error } = await supabaseAdmin
    .from("system_jobs")
    .update({
      status: "failed",
      completed_at: new Date().toISOString(),
      metadata,
      error: message,
    })
    .eq("id", jobId);

  if (error) {
    throw new Error(`Failed to mark system job ${jobId} failed: ${error.message}`);
  }
}


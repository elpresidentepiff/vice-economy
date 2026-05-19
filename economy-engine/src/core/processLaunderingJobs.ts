import { supabaseAdmin } from "../db/supabaseAdmin.js";

type LaunderingJob = {
  id: string;
  started_at: string;
  duration_minutes: number;
};

export type LaunderingTickResult = {
  completed: number;
  skipped: number;
  failures: Array<{ jobId: string; error: string }>;
};

function isReady(job: LaunderingJob, now = new Date()): boolean {
  const startedAt = new Date(job.started_at);
  const readyAt = new Date(startedAt.getTime() + Number(job.duration_minutes) * 60_000);
  return now >= readyAt;
}

export async function processLaunderingJobs(): Promise<LaunderingTickResult> {
  const { data, error } = await supabaseAdmin
    .from("laundering_jobs")
    .select("id, started_at, duration_minutes")
    .eq("status", "pending")
    .order("started_at", { ascending: true });

  if (error) {
    throw new Error(`Failed to fetch laundering jobs: ${error.message}`);
  }

  const jobs = (data ?? []) as LaunderingJob[];
  const failures: Array<{ jobId: string; error: string }> = [];
  let completed = 0;
  let skipped = 0;
  const now = new Date();

  for (const job of jobs) {
    if (!isReady(job, now)) {
      skipped += 1;
      continue;
    }

    const { data: result, error: completeError } = await supabaseAdmin.rpc("complete_laundering", {
      p_job_id: job.id,
    });

    if (completeError) {
      failures.push({ jobId: job.id, error: completeError.message });
      continue;
    }

    if (result?.success === true) {
      completed += 1;
    } else {
      failures.push({ jobId: job.id, error: result?.error ?? "unknown_error" });
    }
  }

  return {
    completed,
    skipped,
    failures,
  };
}


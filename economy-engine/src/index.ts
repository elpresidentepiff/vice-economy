import express from "express";
import { loadConfig } from "./config.js";
import { districtTick } from "./core/districtTick.js";
import { health } from "./core/health.js";
import { marketTick } from "./core/marketTick.js";
import { npcTick } from "./core/npcTick.js";
import { processLaunderingJobs } from "./core/processLaunderingJobs.js";
import { completeSystemJob, failSystemJob, startSystemJob } from "./core/systemJobs.js";

const config = loadConfig();
const app = express();

app.use(express.json());

app.get("/health", (_req, res) => {
  res.status(200).json(health());
});

app.post("/tick/market", async (req, res) => {
  const tickSecret = req.header("x-tick-secret");
  if (!tickSecret || tickSecret !== config.tickSecret) {
    res.status(401).json({ success: false, error: "unauthorized" });
    return;
  }

  const job = await startSystemJob("market_tick", {
    source: "http",
    route: "/tick/market",
  });

  try {
    const result = await marketTick();
    await completeSystemJob(job.id, result.tickId, {
      updated: result.updated,
      skipped: result.skipped,
      updates: result.updates,
    });

    res.status(200).json({ success: true, ...result });
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : "market_tick_failed";
    await failSystemJob(job.id, message).catch((jobError: unknown) => {
      console.error(jobError);
    });

    res.status(500).json({
      success: false,
      error: message,
    });
  }
});

app.post("/tick/launder", async (req, res) => {
  const tickSecret = req.header("x-tick-secret");
  if (!tickSecret || tickSecret !== config.tickSecret) {
    res.status(401).json({ success: false, error: "unauthorized" });
    return;
  }

  const job = await startSystemJob("laundering_tick", {
    source: "http",
    route: "/tick/launder",
  });

  try {
    const result = await processLaunderingJobs();
    await completeSystemJob(job.id, null, result);

    res.status(200).json({ success: true, ...result });
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : "laundering_tick_failed";
    await failSystemJob(job.id, message).catch((jobError: unknown) => {
      console.error(jobError);
    });

    res.status(500).json({
      success: false,
      error: message,
    });
  }
});

app.post("/tick/district", async (req, res) => {
  const tickSecret = req.header("x-tick-secret");
  if (!tickSecret || tickSecret !== config.tickSecret) {
    res.status(401).json({ success: false, error: "unauthorized" });
    return;
  }

  const job = await startSystemJob("district_tick", {
    source: "http",
    route: "/tick/district",
  });

  try {
    const result = await districtTick();
    await completeSystemJob(job.id, result.tickId, {
      updated: result.updated,
      skipped: result.skipped,
      updates: result.updates,
    });

    res.status(200).json({ success: true, ...result });
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : "district_tick_failed";
    await failSystemJob(job.id, message).catch((jobError: unknown) => {
      console.error(jobError);
    });

    res.status(500).json({
      success: false,
      error: message,
    });
  }
});

app.post("/tick/npc", async (req, res) => {
  const tickSecret = req.header("x-tick-secret");
  if (!tickSecret || tickSecret !== config.tickSecret) {
    res.status(401).json({ success: false, error: "unauthorized" });
    return;
  }

  const job = await startSystemJob("npc_tick", {
    source: "http",
    route: "/tick/npc",
  });

  try {
    const result = await npcTick();
    await completeSystemJob(job.id, result.tickId, {
      updated: result.updated,
      skipped: result.skipped,
      updates: result.updates,
    });

    res.status(200).json({ success: true, ...result });
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : "npc_tick_failed";
    await failSystemJob(job.id, message).catch((jobError: unknown) => {
      console.error(jobError);
    });

    res.status(500).json({
      success: false,
      error: message,
    });
  }
});

app.post("/tick/all", async (req, res) => {
  const tickSecret = req.header("x-tick-secret");
  if (!tickSecret || tickSecret !== config.tickSecret) {
    res.status(401).json({ success: false, error: "unauthorized" });
    return;
  }

  const job = await startSystemJob("all_tick", {
    source: "http",
    route: "/tick/all",
  });

  try {
    const market = await marketTick();
    const district = await districtTick();
    const npc = await npcTick();
    const laundering = await processLaunderingJobs();
    await completeSystemJob(job.id, market.tickId, { market, district, npc, laundering });

    res.status(200).json({ success: true, market, district, npc, laundering });
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : "all_tick_failed";
    await failSystemJob(job.id, message).catch((jobError: unknown) => {
      console.error(jobError);
    });

    res.status(500).json({
      success: false,
      error: message,
    });
  }
});

app.listen(config.port, "0.0.0.0", () => {
  console.log(`vice-economy-engine listening on 0.0.0.0:${config.port}`);
});

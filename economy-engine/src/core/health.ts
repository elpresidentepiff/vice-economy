export function health() {
  return {
    status: "ok",
    service: "vice-economy-engine",
    timestamp: new Date().toISOString(),
  };
}


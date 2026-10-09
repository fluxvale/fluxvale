// Heartbeat emitter (docs/deployment.md "Scheduled monitoring"): the
// scheduled smoke run pushes `fluxvale_smoke_heartbeat_count` to the
// hosted Prom via remote-write on FULL success only — any failure
// writes nothing, series absence IS the page (the dead-man's switch,
// tofu/deadman.tf in the fleet repo). Value = the workflow run number,
// so the series charts the cron's progress, not just its existence.
//
// Remote-write is snappy-compressed protobuf (the same endpoint Alloy
// pushes to); hand-rolled encodings are how silent dead-mans get
// shipped, so both steps use the real libraries.
import protobuf from "protobufjs";
import { compress } from "snappyjs";

const WRITE_URL =
  process.env.PROM_REMOTE_WRITE_URL ??
  "https://prometheus-prod-65-prod-eu-west-2.grafana.net/api/prom/push";

const proto = `
syntax = "proto3";
package prometheus;
message Label { string name = 1; string value = 2; }
message Sample {
  double value = 1;
  int64 timestamp = 2;
}
message TimeSeries {
  repeated Label labels = 1;
  repeated Sample samples = 2;
}
message WriteRequest { repeated TimeSeries timeseries = 1; }
`;

const root = protobuf.parse(proto).root;
const WriteRequest = root.lookupType("prometheus.WriteRequest");

function buildBody(metric, value) {
  const request = WriteRequest.create({
    timeseries: [
      {
        labels: [
          { name: "__name__", value: metric },
          { name: "source", value: "gha-smoke" },
        ],
        samples: [{ value, timestamp: Date.now() }],
      },
    ],
  });
  const encoded = WriteRequest.encode(request).finish();
  return compress(encoded);
}

async function pushOnce(metric, value, auth) {
  // Bounded attempt: a hung write must not stall the run until the
  // job timeout — the retries only cover fast failures.
  const response = await fetch(WRITE_URL, {
    method: "POST",
    signal: AbortSignal.timeout(10_000),
    headers: {
      "Content-Type": "application/x-protobuf",
      "Content-Encoding": "snappy",
      "X-Prometheus-Remote-Write-Version": "0.1.0",
      Authorization: `Basic ${Buffer.from(auth).toString("base64")}`,
    },
    body: buildBody(metric, value),
  });
  if (!response.ok) {
    throw new Error(`remote-write ${response.status}: ${await response.text()}`);
  }
}

async function main() {
  const username = process.env.PROM_REMOTE_WRITE_USERNAME;
  const token = process.env.PROM_REMOTE_WRITE_TOKEN;
  const metric = process.env.HEARTBEAT_METRIC ?? "fluxvale_smoke_heartbeat_count";
  const value = Number(process.env.HEARTBEAT_VALUE ?? "1");

  if (!username || !token) {
    throw new Error("PROM_REMOTE_WRITE_USERNAME / PROM_REMOTE_WRITE_TOKEN not set");
  }
  const auth = `${username}:${token}`;

  // Retry like the deploy-annotation curl: a transient 5xx must not
  // read as a dead cron.
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      await pushOnce(metric, value, auth);
      console.log(`heartbeat written: ${metric} = ${value}`);
      return;
    } catch (error) {
      lastError = error;
      console.error(`attempt ${attempt} failed: ${error.message}`);
      await new Promise((resolve) => setTimeout(resolve, 2000 * attempt));
    }
  }
  throw lastError;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

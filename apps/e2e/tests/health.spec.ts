import { expect, test } from "@playwright/test";

// Smoke: the platform is up and reporting its build identity. This is the
// same contract the deploy pipeline greps (docs/deployment.md) — if this
// fails, everything after it will too.
test("health endpoints report ok with a build version", async ({ request }) => {
  const health = await request.get("/health");
  expect(health.status()).toBe(200);

  const body = await health.json();
  expect(body.status).toBe("ok");
  // "dev" locally, "sha-<sha>" on any built image — but never absent
  expect(typeof body.version).toBe("string");
  expect(body.version.length).toBeGreaterThan(0);

  const ready = await request.get("/health/ready");
  expect(ready.status()).toBe(200);

  const readyBody = await ready.json();
  expect(readyBody.status).toBe("ok");
  expect(typeof readyBody.version).toBe("string");
  expect(readyBody.version.length).toBeGreaterThan(0);
});

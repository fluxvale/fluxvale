import { expect, test } from "@playwright/test";
import { waitForLiveViewJoin } from "./helpers/live-view";
import { runtimeFor } from "./helpers/runtime";
import { signIn } from "./helpers/sign-in";
import { TestInbox } from "./helpers/test-inbox";

// S6 (#751): the member custom-hostname mint through the real surfaces —
// the instance page card and the member API. The local stack seeds one
// :custom, :verified AccessDomain (priv/repo/local_seeds.exs) because a
// real verify-by-issuance needs ACME + public DNS; this spec mints and
// removes under that row, then proves the wire list agrees.
//
// Local-only: the seed never reaches staging/production (it lives in
// local_seeds.exs), so another runtime has no verified custom domain to
// mint under.

const testInboxToken = process.env.E2E_TESTINBOX_TOKEN;
const runId = process.env.E2E_RUN_ID ?? `run${Date.now()}`;
const runtime = runtimeFor(process.env.BASE_URL);

test.skip(
  !testInboxToken,
  "E2E_TESTINBOX_TOKEN not set — bootstrap the stack first (apps/e2e/README.md)",
);

test.skip(
  runtime !== "local",
  "the verified custom-domain seed is local-only (priv/repo/local_seeds.exs)",
);

test("custom hostname: mint on the instance page → API list → remove", async ({
  page,
  request,
}) => {
  // The e2e PAT is the seeded admin's; signing in as that same user
  // means the API-created instance and the page share one org.
  const inbox = new TestInbox(request, testInboxToken!);
  await signIn(page, inbox, "admin@fluxvale.com");

  const headers = {
    authorization: `Bearer ${testInboxToken}`,
    "content-type": "application/vnd.api+json",
  };

  // Create the instance through the member API (the e2e PAT carries
  // every scope). The first catalog app is enough — nothing deploys.
  const appsResponse = await request.get("/api/v1/apps", { headers });
  expect(appsResponse.status()).toBe(200);
  const apps = (await appsResponse.json()).data;
  const app = apps[0];

  const versionsResponse = await request.get(
    `/api/v1/apps/${app.id}/versions`,
    { headers },
  );
  expect(versionsResponse.status()).toBe(200);
  const version = (await versionsResponse.json()).data[0];

  const createResponse = await request.post("/api/v1/instances", {
    headers,
    data: {
      data: {
        type: "instance",
        attributes: {
          name: `e2e-hostname-${runId}`,
          app_version_id: version.id,
        },
      },
    },
  });
  expect(createResponse.status()).toBe(201);
  const instance = (await createResponse.json()).data;

  try {
    await page.goto(`/instances/${instance.id}`);
    await waitForLiveViewJoin(page);

    const card = page.getByTestId("instance-hostnames");
    await expect(card).toBeVisible();

    // The local seed's verified domain is one of the select's choices.
    const domainSelect = page.getByTestId("hostname-domain-select");
    const seededOption = domainSelect.locator("option", {
      hasText: "apps.fluxvale.com",
    });
    await expect(seededOption).toHaveCount(1);
    const domainId = await seededOption.getAttribute("value");
    expect(domainId).toBeTruthy();

    await domainSelect.selectOption(domainId!);
    await page.getByTestId("hostname-label-input").fill("git");
    await page.getByTestId("hostname-add").click();

    const address = page.getByTestId("hostname-value");
    await expect(address).toHaveText("git.apps.fluxvale.com");
    await expect(page.getByTestId("hostname-remove")).toBeVisible();

    // The member API agrees with the page — the row is real, not a
    // client-side echo.
    const listResponse = await request.get(
      `/api/v1/instances/${instance.id}/hostnames`,
      { headers },
    );
    expect(listResponse.status()).toBe(200);
    const hostnames = (await listResponse.json()).data;
    expect(
      hostnames.some(
        (row: { attributes: { label: string } }) =>
          row.attributes.label === "git",
      ),
    ).toBe(true);

    // Remove through the card; the row disappears from the page.
    await page.getByTestId("hostname-remove").click();
    await expect(address).toHaveCount(0);
  } finally {
    // Never-deployed instance: the API delete hard-deletes synchronously.
    const deleteResponse = await request.delete(
      `/api/v1/instances/${instance.id}`,
      { headers },
    );
    expect(deleteResponse.status()).toBe(200);
  }
});

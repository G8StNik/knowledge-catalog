const { chromium } = require("playwright");
let input = "";
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", async () => {
  const { origin } = JSON.parse(input);
  let browser;
  try {
    browser = await chromium.launch({ channel: "msedge", headless: true });
    const page = await browser.newPage({
      viewport: { width: 1280, height: 900 },
    });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    // Intercept the hosted provider; this is a local handoff test, not live MFA.
    await page.route("https://example.auth0.com/**", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: "<h1>Hosted sign-in handoff reached</h1>",
      }),
    );
    await page.goto(origin);
    await page
      .getByRole("button", { name: "Continue to secure sign-in" })
      .waitFor();
    if (await page.locator("#login-form").isVisible())
      throw Error("Development login visible in Auth0 mode");
    await page.getByLabel("Organization code").fill("example-company");
    await page.screenshot({
      path: "../auth0-signin-desktop.png",
      fullPage: true,
    });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({
      path: "../auth0-signin-mobile.png",
      fullPage: true,
    });
    if (
      await page.evaluate(
        () => document.documentElement.scrollWidth > innerWidth,
      )
    )
      throw Error("Mobile overflow");
    await page
      .getByRole("button", { name: "Continue to secure sign-in" })
      .click();
    await page
      .getByRole("heading", { name: "Hosted sign-in handoff reached" })
      .waitFor();
    const url = new URL(page.url());
    if (
      url.pathname !== "/authorize" ||
      url.searchParams.get("code_challenge_method") !== "S256" ||
      !url.searchParams.get("nonce")
    )
      throw Error("Incorrect authorization handoff");
    if (errors.length) throw Error(errors.join("\n"));
    console.log("Auth0 browser handoff and responsive sign-in page passed.");
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  } finally {
    await browser?.close();
  }
});

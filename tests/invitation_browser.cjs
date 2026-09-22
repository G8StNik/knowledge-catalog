const { chromium } = require("playwright");
let input = "";
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", async () => {
  const { origin, ticket } = JSON.parse(input);
  const browser = await chromium.launch({ channel: "msedge", headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(origin);
    await page.getByLabel("Access ticket").fill(ticket);
    await page.getByRole("button", { name: "Open workspace" }).click();
    await page.getByRole("button", { name: "People & invitations" }).click();
    await page.getByLabel("Email address").fill("browser.invitee@example.test");
    await page.getByLabel("Can create and edit procedures and sources").check();
    await page.getByRole("button", { name: "Create invitation" }).click();
    const code = await page.getByLabel("One-time invitation code").inputValue();
    if (code.length < 40) throw Error("One-time code missing");
    await page.getByText("browser.invitee@example.test").waitFor();
    await page.getByRole("button", { name: "Revoke invitation" }).click();
    await page.locator("#list small").filter({ hasText: /^REVOKED/ }).waitFor();
    if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth))
      throw Error("Mobile horizontal overflow");
    if (errors.length) throw Error(errors.join("\n"));
  } finally {
    await browser.close();
  }
});

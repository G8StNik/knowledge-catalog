const { chromium } = require("playwright");
let input = "";
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", async () => {
  const config = JSON.parse(input);
  let browser, page;
  try {
    browser = await chromium.launch({ channel: "msedge", headless: true });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 1000 },
    });
    page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("dialog", (d) => d.accept());
    await page.goto(config.origin);
    await page.getByLabel("Access ticket").fill(config.author);
    await page.getByRole("button", { name: "Open workspace" }).click();
    await page.getByRole("button", { name: "Upload source" }).click();
    await page.getByLabel("Document number").fill("POL-UI");
    await page.getByLabel("Document name").fill("Request verification policy");
    await page.getByLabel("Reviewer").check();
    await page.getByLabel("File").setInputFiles({
      name: "verification.md",
      mimeType: "text/markdown",
      buffer: Buffer.from("# Verification policy\nVerify the request and retain approval."),
    });
    await page.getByRole("button", { name: "Upload immutable version" }).click();
    await page.getByText("Source version uploaded. It is available as SOP evidence.", { exact: true }).waitFor();
    await page.getByRole("button", { name: "+ Create SOP" }).click();
    await page.getByLabel("SOP number").fill("UI-001");
    await page
      .getByLabel("Title", { exact: true })
      .fill("Request review procedure");
    await page
      .getByLabel("Summary", { exact: true })
      .fill("A repeatable process with independent approval.");
    await page
      .getByLabel("Procedure", { exact: true })
      .fill("1. Verify the request.\n2. Record approval and retain evidence.");
    await page.locator('[data-field="review_date"]').fill("2027-09-17");
    await page
      .getByRole("button", { name: "Create draft", exact: true })
      .click();
    await page.getByText("Draft created.", { exact: true }).waitFor();
    await page.getByText("Attach source evidence", { exact: true }).click();
    await page.locator('select[name=artifact_version_id]').selectOption({ label: "POL-UI · Version 1" });
    await page.getByLabel("Section or location").fill("Full procedure");
    await page
      .getByRole("button", { name: "Attach evidence", exact: true })
      .click();
    await page.getByText("Evidence attached.", { exact: true }).waitFor();
    for (const [role, person] of [
      ["Owner", "Human"],
      ["Approver", "Reviewer"],
    ]) {
      await page.getByText("Assign a responsibility", { exact: true }).click();
      await page.locator("select[name=role_id]").selectOption({ label: role });
      await page
        .locator("select[name=principal_id]")
        .selectOption({ label: person });
      await page.getByRole("button", { name: "Assign person" }).click();
      await page
        .getByText("Responsibility assigned.", { exact: true })
        .waitFor();
    }
    await page.getByRole("button", { name: "Submit for review" }).click();
    await page
      .getByText("Sent for independent review.", { exact: true })
      .waitFor();
    await page.getByRole("button", { name: "Sign out" }).click();
    await page.getByLabel("Access ticket").fill(config.reviewer);
    await page.getByRole("button", { name: "Open workspace" }).click();
    await page.locator(".item").first().click();
    await page
      .getByLabel("Review note")
      .fill("Verified against the controlled source.");
    await page.getByRole("button", { name: "Approve this version" }).click();
    await page.getByText("Approval recorded.", { exact: true }).waitFor();
    await page
      .getByRole("button", { name: "Publish version", exact: true })
      .click();
    await page
      .getByText("Version published. Its history is preserved.", {
        exact: true,
      })
      .waitFor();
    await page.screenshot({
      path: "../sop-workspace-desktop.png",
      fullPage: true,
    });
    await page.getByRole("button", { name: "Create revision" }).click();
    await page
      .getByText("New draft created. The published version is unchanged.", {
        exact: true,
      })
      .waitFor();
    await page
      .getByLabel("Procedure", { exact: true })
      .fill("Updated draft while version 1 stays published.");
    await page.getByRole("button", { name: "Save draft" }).click();
    await page.getByText("Draft saved.", { exact: true }).waitFor();
    await page
      .getByRole("button", {
        name: "Version 1 · Published · Current",
        exact: true,
      })
      .click();
    if (
      !(await page
        .getByText("1. Verify the request.", { exact: false })
        .isVisible())
    )
      throw Error("Published content missing");
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({
      path: "../sop-workspace-mobile.png",
      fullPage: true,
    });
    if (
      await page.evaluate(
        () => document.documentElement.scrollWidth > window.innerWidth,
      )
    )
      throw Error("Mobile horizontal overflow");
    if (errors.length) throw Error(errors.join("\n"));
    console.log("Browser workflow passed at desktop and mobile sizes.");
  } catch (error) {
    if (page) {
      await page.screenshot({
        path: "../sop-browser-failure.png",
        fullPage: true,
      });
      console.error(await page.locator("body").innerText());
    }
    console.error(error);
    process.exitCode = 1;
  } finally {
    await browser?.close();
  }
});

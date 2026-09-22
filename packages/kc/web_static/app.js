"use strict";
const $ = (s) => document.querySelector(s);
const esc = (s) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
let data,
  selected,
  dirty = false;
const stages = {
  DRAFT: "Draft",
  IN_REVIEW: "Awaiting review",
  APPROVED: "Approved",
  PUBLISHED: "Published",
};
function notice(message, error = false) {
  $("#notice").textContent = message;
  $("#notice").className = error ? "error" : "";
}
async function api(path, payload) {
  const r = await fetch("/api/" + path, {
    method: payload ? "POST" : "GET",
    headers: payload ? { "Content-Type": "application/json" } : {},
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const d = await r.json();
  if (!r.ok) {
    if (r.status === 401) clearSession();
    throw Error(d.error || "Request failed");
  }
  return d;
}
function clearSession() {
  dirty = false;
  data = null;
  selected = null;
  $("#workspace").hidden = true;
  $("#login").hidden = false;
  $("#new").hidden = true;
  $("#logout").hidden = true;
  $("#identity").textContent = "";
  $("#list").replaceChildren();
  $("#detail").replaceChildren();
}
function safe(fn) {
  return async (event) => {
    event?.preventDefault();
    try {
      await fn(event);
    } catch (error) {
      notice(error.message, true);
    }
  };
}
function leave() {
  return !dirty || confirm("Discard your unsaved changes?");
}
window.addEventListener("beforeunload", (e) => {
  if (dirty) {
    e.preventDefault();
    e.returnValue = "";
  }
});
function options(items, id, label, value) {
  return items
    .map(
      (x) =>
        `<option value="${esc(x[id])}" ${x[id] === value ? "selected" : ""}>${esc(x[label])}</option>`,
    )
    .join("");
}
function badge(v) {
  return `<span class="badge ${esc(v.status)}">${esc(stages[v.status])}</span>`;
}
function person(id) {
  return (
    data.people.find((p) => p.principal_id === id)?.display_name ||
    "Catalog member"
  );
}
function role(id) {
  return (
    data.roles.find((p) => p.role_id === id)?.display_name || "Responsibility"
  );
}
async function load(id = selected) {
  data = await api("workspace");
  $("#login").hidden = true;
  $("#workspace").hidden = false;
  $("#new").hidden = false;
  $("#logout").hidden = false;
  $("#identity").textContent = data.actor.display_name;
  selected = id;
  dirty = false;
  list();
  if (id && data.versions.some((v) => v.knowledge_version_id === id))
    detail(id);
  else {
    $("#detail").innerHTML =
      "<h2>Your procedures, in one place.</h2><p>Select an SOP or create a draft to get started.</p>";
    selected = null;
  }
}
function list() {
  const term = $("#search").value.toLowerCase(),
    status = $("#filter").value;
  const items = data.versions.filter(
    (v) =>
      (!status || status === v.status) &&
      `${v.title} ${v.knowledge_key}`.toLowerCase().includes(term),
  );
  $("#list").innerHTML =
    items
      .map(
        (v) =>
          `<button class="item ${selected === v.knowledge_version_id ? "active" : ""}" data-version="${v.knowledge_version_id}"><small>${esc(v.knowledge_key)} · Version ${v.version_number}</small><strong>${esc(v.title)}</strong>${badge(v)} ${v.current_version_id === v.knowledge_version_id ? "<small>Current publication</small>" : ""}</button>`,
      )
      .join("") || "<p>No procedures match this view.</p>";
  $("#list")
    .querySelectorAll("button")
    .forEach(
      (b) =>
        (b.onclick = () => {
          if (leave()) detail(b.dataset.version);
        }),
    );
}
function metadataFields(type, values = {}) {
  return data.fields
    .filter((f) => f.knowledge_type_id === type)
    .map((f) => {
      const value = values[f.key] ?? f.default_value ?? "";
      let input;
      if (f.data_type === "CHOICE")
        input = `<select data-field="${esc(f.key)}"><option value="">Choose…</option>${options(
          data.choices.filter(
            (c) =>
              c.custom_field_definition_id === f.custom_field_definition_id,
          ),
          "value",
          "display_name",
          value,
        )}</select>`;
      else if (f.data_type === "BOOLEAN")
        input = `<select data-field="${esc(f.key)}"><option value="">Choose…</option><option value="true" ${value === true ? "selected" : ""}>Yes</option><option value="false" ${value === false ? "selected" : ""}>No</option></select>`;
      else
        input = `<input data-field="${esc(f.key)}" type="${f.data_type === "DATE" ? "date" : f.data_type === "NUMBER" ? "number" : "text"}" step="any" value="${esc(value)}">`;
      return `<label>${esc(f.display_name)}${f.is_required || f.binding_required ? " · Required for review" : ""}${input}</label>`;
    })
    .join("");
}
function metadata(type, original = {}) {
  const result = { ...original };
  for (const f of data.fields.filter((f) => f.knowledge_type_id === type)) {
    const el = [...document.querySelectorAll("[data-field]")].find(
      (e) => e.dataset.field === f.key,
    );
    if (!el) continue;
    if (el.value === "") {
      delete result[f.key];
      continue;
    }
    result[f.key] =
      f.data_type === "NUMBER"
        ? Number(el.value)
        : f.data_type === "BOOLEAN"
          ? el.value === "true"
          : el.value;
  }
  return result;
}
function watch() {
  $("#detail")
    .querySelectorAll("label")
    .forEach((label) => {
      const control = label.querySelector("input,textarea,select");
      if (control)
        control.setAttribute(
          "aria-label",
          [...label.childNodes]
            .filter((n) => n.nodeType === 3)
            .map((n) => n.textContent)
            .join("")
            .trim(),
        );
    });
  $("#detail")
    .querySelectorAll(
      "#edit-form input,#edit-form textarea,#edit-form select,#create-form input,#create-form textarea,#create-form select,#review-note",
    )
    .forEach((el) => el.addEventListener("input", () => (dirty = true)));
}
async function act(action, payload) {
  notice("");
  const buttons = [...$("#detail").querySelectorAll("button")];
  buttons.forEach((b) => (b.disabled = true));
  try {
    const r = await api("action/" + action, payload);
    dirty = false;
    await load(r.version_id);
    notice(
      {
        create: "Draft created.",
        edit: "Draft saved.",
        submit: "Sent for independent review.",
        review: "Approval recorded.",
        publish: "Version published. Its history is preserved.",
        revise: "New draft created. The published version is unchanged.",
        attach: "Evidence attached.",
        assign: "Responsibility assigned.",
        "return-to-draft": "Returned to draft for changes.",
      }[action],
    );
  } finally {
    buttons.forEach((b) => (b.disabled = false));
  }
}
function create() {
  if (!leave()) return;
  selected = null;
  dirty = false;
  list();
  $("#detail").innerHTML =
    `<p class="eyebrow">START WITH A CLEAR PROCEDURE</p><h2>Create an SOP</h2><form id="create-form"><div class="grid"><label>Workspace<select name="workspace_id" required>${options(data.workspaces, "workspace_id", "workspace_name")}</select></label><label>Knowledge type<select name="knowledge_type_id" required>${options(data.types, "knowledge_type_id", "display_name")}</select></label><label>SOP number<input name="knowledge_key" placeholder="SOP-001" required></label><label>Domain<select name="domain_id" required></select></label></div><label>Title<input name="title" placeholder="What does this procedure help someone do?" required></label><label>Summary<textarea name="summary" rows="2"></textarea></label><label>Procedure<textarea name="content" rows="10" placeholder="Purpose\n\nWhen to use this SOP\n\nSteps\n1.\n2." required></textarea></label><div id="metadata" class="grid"></div><p class="muted">Save your draft first, then attach evidence and assign an owner and reviewer.</p><button class="primary" ${!data.types.length || !data.workspaces.length ? "disabled" : ""}>Create draft</button></form>`;
  const type = $("[name=knowledge_type_id]");
  const sop = data.types.find((t) => t.key === "sop");
  if (sop) type.value = sop.knowledge_type_id;
  function config() {
    const t = data.types.find((t) => t.knowledge_type_id === type.value);
    $("[name=domain_id]").innerHTML = options(
      data.domains.filter(
        (d) => d.configuration_revision_id === t?.configuration_revision_id,
      ),
      "domain_id",
      "display_name",
    );
    $("#metadata").innerHTML = metadataFields(type.value);
    watch();
  }
  type.onchange = config;
  config();
  watch();
  $("#create-form").onsubmit = safe(async () => {
    const p = Object.fromEntries(new FormData($("#create-form")));
    p.configuration_revision_id = data.types.find(
      (t) => t.knowledge_type_id === p.knowledge_type_id,
    ).configuration_revision_id;
    p.metadata = metadata(p.knowledge_type_id);
    await act("create", p);
  });
}
function detail(id) {
  selected = id;
  dirty = false;
  list();
  const v = data.versions.find((v) => v.knowledge_version_id === id),
    draft = v.status === "DRAFT" && v.can_edit;
  const citations = data.citations.filter((c) => c.knowledge_version_id === id),
    responsibilities = data.responsibilities.filter(
      (r) => r.knowledge_version_id === id,
    ),
    reviews = data.reviews.filter((r) => r.knowledge_version_id === id);
  const history = data.versions
    .filter((x) => x.knowledge_item_id === v.knowledge_item_id)
    .sort((a, b) => b.version_number - a.version_number);
  $("#detail").innerHTML =
    `<p class="eyebrow">${esc(v.knowledge_key)} · VERSION ${v.version_number}</p>${badge(v)}<h2>${esc(v.title)}</h2>${v.status === "PUBLISHED" ? '<p class="muted">This publication is preserved. Create a revision to make changes.</p>' : ""}
${
  draft
    ? `<form id="edit-form"><label>Title<input name="title" value="${esc(v.title)}" required></label><label>Summary<textarea name="summary" rows="2">${esc(v.summary)}</textarea></label><label>Procedure<textarea name="content" rows="12" required>${esc(v.content)}</textarea></label><div class="grid">${metadataFields(v.knowledge_type_id, v.custom_metadata)}</div><button class="primary">Save draft</button></form>`
    : `<p>${esc(v.summary)}</p><div class="prose">${esc(v.content)}</div><h3>Details</h3>${Object.entries(
        v.custom_metadata,
      )
        .map(
          ([k, value]) =>
            `<p><strong>${esc(data.fields.find((f) => f.key === k && f.knowledge_type_id === v.knowledge_type_id)?.display_name || k)}</strong>: ${esc(value)}</p>`,
        )
        .join("")}`
}
<h3>Source evidence <small>(${citations.length})</small></h3>${
      citations
        .map((c) => {
          const e = data.evidence.find(
            (e) => e.artifact_version_id === c.artifact_version_id,
          );
          return `<details class="evidence"><summary>${esc(e?.external_key || "Source")} · ${esc(c.locator)}</summary><p>${esc(c.evidence_note)}</p><p class="muted">Source version ${esc(e?.version_key)} · ${esc(e?.source_uri)}</p><div class="prose">${esc(e?.content)}</div></details>`;
        })
        .join("") || "<p>No evidence attached yet.</p>"
    }
${draft ? `<details><summary>Attach source evidence</summary><form id="attach-form"><label>Available source<select name="artifact_version_id" required>${data.evidence.map((e) => `<option value="${e.artifact_version_id}">${esc(e.external_key)} · Version ${esc(e.version_key)}</option>`).join("")}</select></label><label>Section or location<input name="locator" placeholder="Section 2, steps 1–3" required></label><label>How this supports the SOP<textarea name="evidence_note" rows="2"></textarea></label><button ${data.evidence.length ? "" : "disabled"}>Attach evidence</button></form><p class="muted">Only sources you can access appear here. Ask your administrator to ingest missing evidence.</p></details>` : ""}
<h3>Responsibilities</h3>${responsibilities.map((r) => `<p>${esc(role(r.role_id))} <strong>${esc(person(r.principal_id))}</strong></p>`).join("") || "<p>No responsibilities assigned yet.</p>"}
${
  draft
    ? `<details><summary>Assign a responsibility</summary><form id="assign-form"><div class="grid"><label>Role<select name="role_id" required>${options(
        data.roles.filter(
          (r) => r.configuration_revision_id === v.configuration_revision_id,
        ),
        "role_id",
        "display_name",
      )}</select></label><label>Person<select name="principal_id" required>${options(data.people, "principal_id", "display_name")}</select></label></div><button>Assign person</button></form></details>`
    : ""
}
<h3>Review history</h3>${reviews.map((r) => `<div class="evidence"><strong>${esc(person(r.reviewer_id))}</strong><p>${esc(r.note)}</p><small>Review round ${r.review_round} · ${esc(new Date(r.reviewed_at).toLocaleString())}</small></div>`).join("") || "<p>No approvals recorded. A person who contributed to this version cannot approve it.</p>"}
${v.status === "IN_REVIEW" && v.can_review ? '<label>Review note<textarea id="review-note" rows="3" placeholder="Describe how you verified the procedure and its sources."></textarea></label>' : ""}
<div class="actions">${draft ? '<button data-action="submit" class="primary">Submit for review</button>' : ""}${v.status === "IN_REVIEW" && v.can_review ? '<button data-action="review" class="primary">Approve this version</button>' : ""}${v.status === "IN_REVIEW" && v.can_edit ? '<button data-action="return-to-draft">Return for changes</button>' : ""}${v.status === "APPROVED" && v.can_review ? '<button data-action="publish" class="primary">Publish version</button>' : ""}${v.status === "PUBLISHED" && v.current_version_id === id && v.can_edit && !history.some((x) => x.status !== "PUBLISHED") ? '<button data-action="revise" class="primary">Create revision</button>' : ""}</div>
<h3>Version history</h3>${history.map((x) => `<button class="history" data-id="${x.knowledge_version_id}">Version ${x.version_number} · ${esc(stages[x.status])}${x.current_version_id === x.knowledge_version_id ? " · Current" : ""}</button>`).join(" ")}`;
  if (draft) {
    $("#edit-form").onsubmit = safe(() =>
      act("edit", {
        version_id: id,
        ...Object.fromEntries(new FormData($("#edit-form"))),
        metadata: metadata(v.knowledge_type_id, v.custom_metadata),
      }),
    );
    for (const action of ["attach", "assign"])
      $("#" + action + "-form").onsubmit = safe(() => {
        if (
          dirty &&
          !confirm(
            "This action refreshes the page. Save any procedure edits first. Continue?",
          )
        )
          return;
        return act(action, {
          version_id: id,
          ...Object.fromEntries(new FormData($("#" + action + "-form"))),
        });
      });
  }
  $("#detail")
    .querySelectorAll("[data-action]")
    .forEach(
      (b) =>
        (b.onclick = safe(async () => {
          const action = b.dataset.action;
          const note = $("#review-note")?.value.trim();
          if (action === "review" && !note)
            throw Error("Add a review note before approving.");
          if (action !== "review" && !leave()) return;
          if (
            ["publish", "review"].includes(action) &&
            !confirm(
              action === "publish"
                ? "Publish this version? Its contents and history will be preserved."
                : "Record your approval of this exact version and its source evidence?",
            )
          )
            return;
          await act(action, {
            version_id: id,
            ...(action === "review" ? { note } : {}),
          });
        })),
    );
  $("#detail")
    .querySelectorAll(".history")
    .forEach(
      (b) =>
        (b.onclick = () => {
          if (leave()) detail(b.dataset.id);
        }),
    );
  watch();
}
$("#login-form").onsubmit = safe(async () => {
  await api("login", { ticket: $("[name=ticket]").value });
  $("[name=ticket]").value = "";
  await load();
  notice("Workspace ready.");
});
$("#logout").onclick = safe(async () => {
  if (!leave()) return;
  const result = await api("logout", {});
  if (result.url) {
    clearSession();
    window.location.assign(result.url);
    return;
  }
  dirty = false;
  data = null;
  selected = null;
  $("#workspace").hidden = true;
  $("#login").hidden = false;
  $("#new").hidden = true;
  $("#logout").hidden = true;
  $("#identity").textContent = "";
  $("#list").replaceChildren();
  $("#detail").replaceChildren();
  notice("Signed out.");
});
$("#new").onclick = create;
$("#search").oninput = list;
$("#filter").onchange = list;
$("#refresh").onclick = safe(() => {
  if (leave()) return load();
});
$("#auth0-form").onsubmit = safe(async () => {
  const button = $("#auth0-form button");
  button.disabled = true;
  try {
    const result = await api("auth/start", {
      organization: $("[name=organization]").value.trim(),
    });
    window.location.assign(result.url);
  } finally {
    button.disabled = false;
  }
});
async function initializeSignIn() {
  const config = await api("auth/config");
  const normal = config.mode === "auth0";
  $("#auth0-form").hidden = !normal;
  $("#login-form").hidden = normal;
  $("#signin-description").textContent = normal
    ? "Use your organization's sign-in to securely access your procedures."
    : "Development mode: use a short-lived access ticket. Two-factor authentication is not enabled in this mode.";
  if (new URLSearchParams(window.location.search).has("signin")) {
    notice(
      "Sign-in could not be completed. Try again, or ask your administrator to check MFA and your organization membership.",
      true,
    );
    window.history.replaceState({}, "", "/");
  }
  try {
    await load();
  } catch (error) {
    if (config.mode !== "auth0" && !$("#login").hidden)
      notice(error.message, true);
  }
}
initializeSignIn().catch(() =>
  notice("Sign-in is unavailable. Please try again shortly.", true),
);

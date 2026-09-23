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
  selectedSource = null,
  view = "procedures",
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
  selectedSource = null;
  view = "procedures";
  $("#people-tab").hidden = true;
  $("#workspace").hidden = true;
  $("#login").hidden = false;
  $("#new").hidden = true;
  $("#upload-source").hidden = true;
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
  try {
    data.invitations = (await api("organization/invitations")).invitations;
    $("#people-tab").hidden = false;
  } catch {
    data.invitations = null;
    $("#people-tab").hidden = true;
    if (view === "people") view = "procedures";
  }
  $("#login").hidden = true;
  $("#workspace").hidden = false;
  $("#new").hidden = false;
  $("#upload-source").hidden = false;
  $("#logout").hidden = false;
  $("#identity").textContent = data.actor.display_name;
  selected = id;
  dirty = false;
  setView(view);
  if (view === "people") return peopleDetail();
  if (view === "sources") {
    if (selectedSource) await sourceDetail(selectedSource);
    else sourceWelcome();
    return;
  }
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
  if (view === "people") return invitationList();
  if (view === "sources") return sourceList();
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
function setView(next) {
  if (view !== next) $("#search").value = "";
  view = next;
  for (const [name, button] of [["procedures", "#procedures-tab"], ["sources", "#sources-tab"], ["people", "#people-tab"]]) {
    $(button).classList.toggle("active", name === view);
    $(button).setAttribute("aria-pressed", String(name === view));
  }
  $("#stage-filter").hidden = view !== "procedures";
  $("#search-label").textContent = view === "sources" ? "Find a source" : view === "people" ? "Find an invitation" : "Find a procedure";
  $("#search").placeholder = view === "sources" ? "Search document name, number or text" : view === "people" ? "Search email or status" : "Search title or SOP number";
  list();
}
function invitationList() {
  const term = $("#search").value.toLowerCase();
  $("#list").innerHTML = (data.invitations || []).filter((i) => `${i.email} ${i.status}`.toLowerCase().includes(term))
    .map((i) => `<div class="item"><small>${esc(i.status)} · Expires ${esc(new Date(i.expires_at).toLocaleDateString())}</small><strong>${esc(i.email)}</strong><small>${i.can_edit ? "Can edit" : "Can read"}${i.can_review ? " · Can review" : ""}</small>${i.status === "PENDING" ? `<button data-revoke="${i.invitation_id}">Revoke invitation</button>` : ""}</div>`).join("") || "<p>No invitations match this view.</p>";
  $("#list").querySelectorAll("[data-revoke]").forEach((button) => button.onclick = safe(async () => {
    await api("organization/revoke", {invitation_id: button.dataset.revoke});
    await load();
    notice("Invitation revoked.");
  }));
}
function peopleDetail() {
  $("#detail").innerHTML = `<p class="eyebrow">ORGANIZATION ONBOARDING</p><h2>Invite a person</h2><p>Create a one-time code for someone who should join this organization. Share it with the intended person through your normal trusted channel. The code expires after seven days and is shown only once.</p><form id="invite-form"><label>Email address<input name="email" type="email" autocomplete="off" required></label><label>Workspace<select name="workspace_id" required>${options(data.workspaces, "workspace_id", "workspace_name")}</select></label><fieldset><legend>Workspace permissions</legend><label><input class="inline" type="checkbox" name="can_edit"> Can create and edit procedures and sources</label><label><input class="inline" type="checkbox" name="can_review"> Can review and publish procedures</label></fieldset><button class="primary" ${data.workspaces.length ? "" : "disabled"}>Create invitation</button></form><div id="invitation-result"></div><h3>Current members</h3>${data.people.map((person) => `<p>${esc(person.display_name)} · ${esc(person.status)} ${person.status === "ACTIVE" && person.principal_id !== data.actor.principal_id ? `<button data-deactivate="${person.principal_id}">Remove access</button>` : ""}</p>`).join("") || "<p>No members yet.</p>"}`;
  $("#detail").querySelectorAll("[data-deactivate]").forEach((button) => button.onclick = safe(async () => {
    if (!confirm("Remove this person's access to the organization? Their published work will remain in the catalog.")) return;
    await api("organization/deactivate-member", {principal_id: button.dataset.deactivate});
    await load();
    notice("Member access removed.");
  }));
  watch();
  $("#invite-form").onsubmit = safe(async () => {
    const form = $("#invite-form");
    const result = await api("organization/invite", {
      email: form.elements.email.value.trim(), workspace_id: form.elements.workspace_id.value,
      can_edit: form.elements.can_edit.checked, can_review: form.elements.can_review.checked,
    });
    const code = result.invitation_code;
    $("#invitation-result").innerHTML = `<h3>Invitation created</h3><p>Share this code privately. It will not be shown again.</p><label>One-time invitation code<input id="invitation-code" readonly></label><button id="copy-invitation">Copy code</button>`;
    $("#invitation-code").value = code;
    $("#copy-invitation").onclick = safe(async () => {
      await navigator.clipboard.writeText(code);
      notice("Invitation code copied.");
    });
    data.invitations = (await api("organization/invitations")).invitations;
    invitationList();
    form.reset();
    notice("Invitation created. Share the code with the intended person.");
  });
}
function sourceDocuments() {
  const documents = new Map();
  for (const evidence of data.evidence)
    if (!documents.has(evidence.source_artifact_id)) documents.set(evidence.source_artifact_id, evidence);
  return [...documents.values()];
}
function sourceWelcome() {
  selectedSource = null;
  $("#detail").innerHTML = "<h2>Source Library</h2><p>Select a document to inspect its versions, citations and access, or upload a source.</p>";
}
function sourceList() {
  const term = $("#search").value.trim().toLowerCase();
  const documents = sourceDocuments().filter((d) => {
    const versions = data.evidence.filter((e) => e.source_artifact_id === d.source_artifact_id);
    return `${d.title} ${d.external_key} ${versions.map((v) => `${v.file_name || ""} ${v.content}`).join(" ")}`.toLowerCase().includes(term);
  });
  $("#list").innerHTML = documents.map((d) => {
    const count = data.evidence.filter((e) => e.source_artifact_id === d.source_artifact_id).length;
    const cited = data.citations.some((c) => data.evidence.some((e) => e.source_artifact_id === d.source_artifact_id && e.artifact_version_id === c.artifact_version_id));
    return `<button class="item ${selectedSource === d.source_artifact_id ? "active" : ""}" data-source="${d.source_artifact_id}"><small>${esc(d.external_key)} · ${count} version${count === 1 ? "" : "s"}</small><strong>${esc(d.title)}</strong><small>${cited ? "Cited by an accessible SOP" : "No visible SOP citations"}</small></button>`;
  }).join("") || "<p>No sources match this view.</p>";
  $("#list").querySelectorAll("[data-source]").forEach((button) => button.onclick = safe(async () => {
    if (leave()) await sourceDetail(button.dataset.source);
  }));
}
async function sourceDetail(artifactId) {
  const versions = data.evidence.filter((e) => e.source_artifact_id === artifactId);
  if (!versions.length) return sourceWelcome();
  selectedSource = artifactId;
  sourceList();
  const latest = versions[0];
  const classification = data.classifications.find((c) => c.classification_id === latest.classification_id)?.display_name || "Unclassified source";
  const workspace = data.workspaces.find((w) => w.workspace_id === latest.owning_workspace_id)?.workspace_name || "Workspace";
  const editable = data.workspaces.some((w) => w.workspace_id === latest.owning_workspace_id);
  const citations = data.citations.filter((c) => versions.some((e) => e.artifact_version_id === c.artifact_version_id));
  $("#detail").innerHTML = `<p class="eyebrow">SOURCE LIBRARY</p><h2>${esc(latest.title)}</h2><div class="source-meta"><span>Number: ${esc(latest.external_key)}</span><span>Owner: ${esc(person(latest.owner_principal_id))}</span><span>Classification: ${esc(classification)}</span><span>Workspace: ${esc(workspace)}</span></div><p>${citations.length} visible SOP citation${citations.length === 1 ? "" : "s"} · ${versions.length} preserved version${versions.length === 1 ? "" : "s"}</p>${editable ? '<button id="new-source-version">Upload new version</button> <button id="manage-access">Manage readers</button>' : ""}<h3>Version history</h3>${versions.map((v, index) => {
    const state = v.effective_to && v.effective_to < new Date().toISOString().slice(0, 10) ? "Expired" : index ? "Superseded" : "Latest";
    const references = citations.filter((c) => c.artifact_version_id === v.artifact_version_id);
    return `<section class="source-version"><h3>Version ${esc(v.version_key)} · ${esc(state)}</h3><div class="source-meta"><span>File: ${esc(v.file_name || "External source")}</span><span>Captured: ${esc(new Date(v.captured_at).toLocaleDateString())}</span><span>Effective: ${esc(v.effective_from || "Not set")}</span><span>End: ${esc(v.effective_to || "Not set")}</span></div><details><summary>Read extracted text</summary><div class="prose">${esc(v.content)}</div></details><details><summary>Source details</summary><p>Media type: ${esc(v.media_type || "External")}<br>Text fingerprint: ${esc(v.content_hash)}<br>Original file fingerprint: ${esc(v.original_content_hash || "Not stored")}</p></details><h4>Cited by</h4>${references.map((c) => {
      const sop = data.versions.find((item) => item.knowledge_version_id === c.knowledge_version_id);
      return sop ? `<button class="citation-link" data-version="${sop.knowledge_version_id}">${esc(sop.knowledge_key)} · ${esc(sop.title)} · ${esc(c.locator)}</button>` : "";
    }).join("") || "<p>No visible SOP cites this version.</p>"}</section>`;
  }).join("")}<div id="access-panel"></div>`;
  $("#new-source-version")?.addEventListener("click", () => uploadSource(artifactId));
  $("#manage-access")?.addEventListener("click", safe(async () => showAccess(artifactId)));
  $("#detail").querySelectorAll(".citation-link").forEach((button) => button.onclick = () => {
    setView("procedures");
    detail(button.dataset.version);
  });
}
async function showAccess(artifactId) {
  const result = await api(`source/access?artifact=${encodeURIComponent(artifactId)}`);
  const panel = $("#access-panel");
  const owner = data.evidence.find((e) => e.source_artifact_id === artifactId)?.owner_principal_id;
  panel.innerHTML = `<h3>Reader access</h3><p class="muted">Only members of this workspace can receive access. Changes apply to every source version.</p>${result.members.map((p) => {
    const active = p.is_allowed && p.valid_until && new Date(p.valid_until) > new Date();
    const protectedReader = active && (p.principal_id === data.actor.principal_id || p.principal_id === owner);
    return `<p><span>${esc(p.display_name)}</span> · ${active ? "Can read" : "No access"} ${protectedReader ? "<small>Required access</small>" : `<button data-principal="${p.principal_id}" data-allowed="${!active}">${active ? "Remove access" : "Give access"}</button>`}</p>`;
  }).join("")}`;
  panel.querySelectorAll("[data-principal]").forEach((button) => button.onclick = safe(async () => {
    await api("source/access", {artifact_id: artifactId, principal_id: button.dataset.principal, allowed: button.dataset.allowed === "true"});
    await load();
    notice("Source access updated.");
    await showAccess(artifactId);
  }));
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
function uploadSource(preselected = null) {
  if (!leave()) return;
  selected = null;
  dirty = false;
  list();
  const documents = sourceDocuments().filter((e) => data.workspaces.some((w) => w.workspace_id === e.owning_workspace_id));
  const revision = data.types.find((t) => t.key === "sop")?.configuration_revision_id || data.types[0]?.configuration_revision_id;
  $("#detail").innerHTML = `<p class="eyebrow">TRUSTED SOURCE EVIDENCE</p><h2>Upload a source document</h2><p>The original file and extracted text are preserved as an immutable version. PDF, text, and Markdown files up to 10 MB are supported.</p><form id="source-form"><label>Existing document <select name="source_artifact_id"><option value="">Create a new document</option>${documents.map((d) => `<option value="${d.source_artifact_id}">${esc(d.title)} · Latest version ${esc(d.version_key)}</option>`).join("")}</select></label><div id="new-source-fields"><div class="grid"><label>Workspace<select name="workspace_id" required>${options(data.workspaces, "workspace_id", "workspace_name")}</select></label><label>Document number<input name="document_key" placeholder="POLICY-001" required></label></div><label>Document name<input name="title" placeholder="Information handling policy" required></label><div class="grid"><label>Owner<select name="owner_principal_id" required>${options(data.people, "principal_id", "display_name", data.actor.principal_id)}</select></label><label>Classification<select name="classification_id" required>${options(data.classifications.filter((c) => c.configuration_revision_id === revision), "classification_id", "display_name")}</select></label></div></div><div class="grid"><label>Effective date<input name="effective_from" type="date"></label><label>End date<input name="effective_to" type="date"></label></div><label>File<input name="file" type="file" accept=".pdf,.txt,.md,text/plain,text/markdown,application/pdf" required></label><fieldset><legend>Give access</legend><p class="muted">The uploader is always granted access. Select other workspace members who may read and cite every version of this source.</p>${data.people.map((p) => `<label><input class="inline" type="checkbox" name="principal_ids" value="${p.principal_id}"> ${esc(p.display_name)}</label>`).join("")}</fieldset><button class="primary">Upload immutable version</button></form>`;
  const existing = $("[name=source_artifact_id]");
  if (typeof preselected === "string") existing.value = preselected;
  const newFields = $("#new-source-fields");
  const updateMode = () => {
    const doc = documents.find((d) => d.source_artifact_id === existing.value);
    newFields.hidden = !!doc;
    newFields.querySelectorAll("input,select").forEach((el) => (el.required = !doc));
  };
  existing.onchange = updateMode;
  updateMode();
  watch();
  $("#source-form").onsubmit = safe(async () => {
    const form = $("#source-form");
    const values = Object.fromEntries(new FormData(form));
    const file = form.elements.file.files[0];
    if (!file || file.size > 10 * 1024 * 1024) throw Error("Choose a file no larger than 10 MB.");
    const media = file.type || ({ pdf: "application/pdf", md: "text/markdown", txt: "text/plain" }[file.name.split(".").pop().toLowerCase()]);
    if (!["application/pdf", "text/plain", "text/markdown"].includes(media)) throw Error("Choose a PDF, text, or Markdown file.");
    const doc = documents.find((d) => d.source_artifact_id === values.source_artifact_id);
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 32768) binary += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
    const payload = {
      workspace_id: doc?.owning_workspace_id || values.workspace_id,
      configuration_revision_id: doc?.configuration_revision_id || revision,
      classification_id: doc?.classification_id || values.classification_id,
      document_key: doc?.external_key || values.document_key,
      title: doc?.title || values.title,
      owner_principal_id: doc?.owner_principal_id || values.owner_principal_id,
      source_artifact_id: values.source_artifact_id || undefined,
      effective_from: values.effective_from || undefined,
      effective_to: values.effective_to || undefined,
      principal_ids: [...form.querySelectorAll('[name=principal_ids]:checked')].map((x) => x.value),
      file_name: file.name,
      media_type: media,
      content_base64: btoa(binary),
    };
    notice("Uploading and extracting text…");
    const uploaded = await api("source/upload", payload);
    dirty = false;
    view = "sources";
    selectedSource = doc?.source_artifact_id || null;
    await load();
    if (!selectedSource) {
      const created = data.evidence.find((e) => e.artifact_version_id === uploaded.artifact_version_id);
      if (created) await sourceDetail(created.source_artifact_id);
    }
    notice("Source version uploaded. It is available as SOP evidence.");
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
  $("#upload-source").hidden = true;
  $("#logout").hidden = true;
  $("#identity").textContent = "";
  $("#list").replaceChildren();
  $("#detail").replaceChildren();
  notice("Signed out.");
});
$("#new").onclick = create;
$("#upload-source").onclick = () => uploadSource();
$("#procedures-tab").onclick = () => {
  if (leave()) { setView("procedures"); selected ? detail(selected) : $("#detail").innerHTML = "<h2>Your procedures, in one place.</h2><p>Select an SOP or create a draft to get started.</p>"; }
};
$("#sources-tab").onclick = () => {
  if (leave()) { setView("sources"); selectedSource ? sourceDetail(selectedSource) : sourceWelcome(); }
};
$("#people-tab").onclick = () => {
  if (leave()) { setView("people"); peopleDetail(); }
};
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
      invitation: $("[name=invitation]").value.trim() || undefined,
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

(function () {
    "use strict";

    const model = window.VersoEditorModel;
    const renderer = window.VersoEditorRenderer;
    const editor = document.querySelector("[data-editor]");
    if (!model || !renderer || !editor) return;

    const ICONS = {
        check: '<path d="m4 9 3.3 3.3L14 5.7"/>',
        copy: '<rect x="6" y="6" width="8" height="8" rx="1"/><path d="M4 11V4.8A.8.8 0 0 1 4.8 4H11"/>',
        delete: '<path d="M4 6h10M6 6v7.5a.5.5 0 0 0 .5.5h5a.5.5 0 0 0 .5-.5V6M7 4h4M7.5 8.5v3M10.5 8.5v3"/>',
        details: '<path d="M4 5h10M4 9h10M4 13h10"/><circle class="fill" cx="7" cy="5" r="1"/><circle class="fill" cx="11" cy="9" r="1"/><circle class="fill" cx="6" cy="13" r="1"/>',
        edit: '<path d="m4 12.5-.5 2 2-.5L13.8 5.7a1.4 1.4 0 0 0-2-2L4 12.5Z"/><path d="m10.8 4.7 2 2"/>',
        image: '<rect x="3" y="4" width="12" height="10" rx="1"/><circle cx="7" cy="7.5" r="1"/><path d="m4 12 3.2-3 2.3 2 1.6-1.5L14 12.5"/>',
        plus: '<path d="M9 4v10M4 9h10"/>',
        text: '<path d="M4 5h10M9 5v9M6.5 14h5"/>',
        up: '<path d="m5 10 4-4 4 4M9 6v9"/>',
        down: '<path d="m5 8 4 4 4-4M9 12V3"/>',
    };

    let idSequence = 0;
    const idFactory = () => "local-" + (++idSequence).toString(36);
    let documentState = model.createDocument({ sections: [] }, idFactory);
    let titleMode = "edit";
    let detailsOpen = false;
    let activeSectionId = null;
    const sectionModes = new Map();
    const sectionPreviewHtml = new Map();
    const sectionErrors = new Map();
    const sectionSchedulers = new Map();

    const list = editor.querySelector("[data-section-list]");
    const count = editor.querySelector("[data-section-count]");
    const status = editor.querySelector("[data-editor-status]");
    const titleEditor = editor.querySelector("[data-title-editor]");
    const titleActions = editor.querySelector("[data-title-actions]");
    const detailsPanel = editor.querySelector("[data-details-panel]");

    function icon(name) {
        const span = document.createElement("span");
        span.className = "icon";
        span.setAttribute("aria-hidden", "true");
        span.innerHTML = '<svg viewBox="0 0 18 18" focusable="false">' + (ICONS[name] || "") + "</svg>";
        return span;
    }

    function iconButton(name, label, action, sectionId) {
        const element = document.createElement("button");
        element.type = "button";
        element.className = "icon-button";
        element.title = label;
        element.setAttribute("aria-label", label);
        element.dataset.action = action;
        if (sectionId) element.dataset.sectionId = sectionId;
        element.appendChild(icon(name));
        return element;
    }

    function sectionMode(id) {
        return sectionModes.get(id) || "edit";
    }

    function schedulerFor(id) {
        let scheduler = sectionSchedulers.get(id);
        if (!scheduler) {
            scheduler = renderer.createPreviewRenderer();
            sectionSchedulers.set(id, scheduler);
        }
        return scheduler;
    }

    function invalidateSection(id) {
        schedulerFor(id).cancel();
        sectionModes.set(id, "edit");
        sectionPreviewHtml.delete(id);
        sectionErrors.delete(id);
    }

    function setActiveSection(id) {
        activeSectionId = id || null;
        list.querySelectorAll(".section-card").forEach((card) => {
            card.classList.toggle("is-active", card.dataset.sectionId === activeSectionId);
        });
    }

    function renderTitle() {
        titleEditor.textContent = documentState.title;
        if (titleMode === "edit") {
            titleEditor.contentEditable = "true";
            titleEditor.setAttribute("aria-label", "Edit document title");
        } else {
            titleEditor.contentEditable = "false";
            titleEditor.setAttribute("aria-label", "Document title");
        }
        titleActions.replaceChildren(iconButton(
            titleMode === "edit" ? "check" : "edit",
            titleMode === "edit" ? "Validate title" : "Edit title",
            titleMode === "edit" ? "validate-title" : "edit-title",
        ));
        const description = editor.querySelector("[data-article-description]");
        description.textContent = documentState.description;
        description.hidden = !documentState.description;
    }

    function detailsField(fieldName, value, placeholder, multiline) {
        const field = document.createElement(multiline ? "textarea" : "input");
        field.dataset.field = fieldName;
        field.setAttribute("aria-label", placeholder);
        field.placeholder = placeholder;
        field.value = value || "";
        if (multiline) field.rows = 2;
        return field;
    }

    function renderDetails() {
        detailsPanel.hidden = !detailsOpen;
        detailsPanel.replaceChildren();
        if (!detailsOpen) return;
        const grid = document.createElement("div");
        grid.className = "details-grid";
        grid.append(
            detailsField("slug", documentState.slug, "URL slug", false),
            detailsField("description", documentState.description, "Short description", true),
        );
        detailsPanel.appendChild(grid);
    }

    function renderHeader() {
        const detailsButton = editor.querySelector('[data-action="toggle-details"]');
        detailsButton.replaceChildren(icon("details"));
        detailsButton.setAttribute("aria-pressed", String(detailsOpen));
        editor.querySelectorAll('[data-action="add-section"]').forEach((button) => {
            button.replaceChildren(icon(button.dataset.kind === "image" ? "image" : "text"));
        });
        renderTitle();
        renderDetails();
    }

    function textField(section) {
        const textarea = document.createElement("textarea");
        textarea.value = section.markdown;
        textarea.dataset.field = "markdown";
        textarea.dataset.sectionId = section.id;
        textarea.setAttribute("aria-label", "Markdown content");
        textarea.spellcheck = false;
        return textarea;
    }

    function imageField(section, fieldName, placeholder) {
        const input = document.createElement("input");
        input.type = "text";
        input.value = section[fieldName] || "";
        input.placeholder = placeholder;
        input.dataset.field = fieldName;
        input.dataset.sectionId = section.id;
        input.setAttribute("aria-label", placeholder);
        return input;
    }

    function sectionCard(section, index) {
        const mode = sectionMode(section.id);
        const card = document.createElement("article");
        card.className = "section-card " + section.kind + "-section" + (section.id === activeSectionId ? " is-active" : "");
        card.dataset.sectionId = section.id;
        card.tabIndex = 0;

        const actions = document.createElement("div");
        actions.className = "section-actions";
        const up = iconButton("up", "Move section up", "move-up", section.id);
        up.disabled = index === 0;
        const down = iconButton("down", "Move section down", "move-down", section.id);
        down.disabled = index === documentState.sections.length - 1;
        actions.append(up, down, iconButton("copy", "Duplicate section", "duplicate", section.id), iconButton("delete", "Delete section", "delete", section.id));
        actions.appendChild(iconButton(mode === "preview" ? "edit" : "check", mode === "preview" ? "Edit section" : "Validate section", mode === "preview" ? "edit-section" : "validate-section", section.id));
        card.appendChild(actions);

        const body = document.createElement("div");
        body.className = mode === "preview" ? "section-card-body section-preview" : "section-card-body section-editor";
        if (mode === "preview") {
            body.innerHTML = sectionPreviewHtml.get(section.id) || renderer.renderSection(section);
        } else if (section.kind === "text") {
            body.appendChild(textField(section));
        } else {
            const imageEditor = document.createElement("div");
            imageEditor.className = "image-editor";
            const note = document.createElement("div");
            note.className = "asset-note";
            note.textContent = "Image upload is not part of the unsaved editor yet.";
            const fields = document.createElement("div");
            fields.className = "image-fields";
            fields.append(imageField(section, "asset", "Asset name"), imageField(section, "alt", "Alt text"));
            imageEditor.append(note, fields, imageField(section, "caption", "Caption"));
            body.appendChild(imageEditor);
        }
        if (sectionErrors.has(section.id)) {
            const error = document.createElement("p");
            error.className = "validation-error";
            error.textContent = sectionErrors.get(section.id);
            body.appendChild(error);
        }
        card.appendChild(body);
        return card;
    }

    function render() {
        renderHeader();
        list.replaceChildren();
        if (documentState.sections.length === 0) {
            const empty = document.createElement("p");
            empty.className = "empty-state";
            empty.textContent = "Your article is empty. Add text or an image placeholder to begin.";
            list.appendChild(empty);
        } else {
            documentState.sections.forEach((section, index) => list.appendChild(sectionCard(section, index)));
        }
        const sectionCount = documentState.sections.length;
        count.textContent = sectionCount + " section" + (sectionCount === 1 ? "" : "s");
        status.textContent = "Unsaved browser-local document · " + sectionCount + " section" + (sectionCount === 1 ? "" : "s");
        window.__versoEditorState = documentState;
    }

    function updateField(target) {
        const changes = {};
        changes[target.dataset.field] = target.value;
        if (target.dataset.sectionId) {
            invalidateSection(target.dataset.sectionId);
            documentState = model.updateSection(documentState, target.dataset.sectionId, changes, idFactory);
        } else {
            documentState = model.updateMetadata(documentState, changes);
            if (target.dataset.field === "description") renderTitle();
        }
        window.__versoEditorState = documentState;
        status.textContent = "Unsaved browser-local document · changes are held in memory";
    }

    function updateTitle(target) {
        documentState = model.updateMetadata(documentState, { title: target.textContent.replace(/\s+/g, " ").trim() });
        window.__versoEditorState = documentState;
        status.textContent = "Unsaved browser-local document · changes are held in memory";
    }

    function validateSection(sectionId) {
        const section = documentState.sections.find((candidate) => candidate.id === sectionId);
        if (!section) return;
        sectionErrors.delete(sectionId);
        status.textContent = "Validating local section preview…";
        schedulerFor(sectionId).request(section, (html) => {
            sectionPreviewHtml.set(sectionId, html);
            sectionModes.set(sectionId, "preview");
            render();
        }).catch(() => {
            sectionErrors.set(sectionId, "This section could not be rendered safely. It remains in edit mode.");
            render();
        });
    }

    editor.addEventListener("input", (event) => {
        if (event.target.matches("[data-title-editor]")) updateTitle(event.target);
        else if (event.target.matches("[data-field]")) updateField(event.target);
    });

    editor.addEventListener("keydown", (event) => {
        if (event.target.matches("[data-title-editor]") && event.key === "Enter") {
            event.preventDefault();
            titleMode = "preview";
            render();
        }
        if (event.target.matches(".section-card") && (event.key === "Enter" || event.key === " ")) {
            event.preventDefault();
            setActiveSection(event.target.dataset.sectionId);
        }
    });

    editor.addEventListener("click", (event) => {
        const card = event.target.closest(".section-card");
        const target = event.target.closest("[data-action]");
        if (card && !target) setActiveSection(card.dataset.sectionId);
        if (!target) return;
        const action = target.dataset.action;
        const sectionId = target.dataset.sectionId;
        if (sectionId) setActiveSection(sectionId);
        if (action === "toggle-details") {
            detailsOpen = !detailsOpen;
            render();
        } else if (action === "validate-title") {
            titleMode = "preview";
            render();
        } else if (action === "edit-title") {
            titleMode = "edit";
            render();
            titleEditor.focus();
        } else if (action === "validate-section") {
            validateSection(sectionId);
        } else if (action === "edit-section") {
            invalidateSection(sectionId);
            render();
        } else if (action === "add-section") {
            const section = target.dataset.kind === "image"
                ? { kind: "image", asset: "", alt: "", caption: "", display: "inline" }
                : { kind: "text", markdown: "" };
            documentState = model.insertSection(documentState, documentState.sections.length, section, idFactory);
            activeSectionId = documentState.sections[documentState.sections.length - 1].id;
            render();
        } else if (action === "delete") {
            invalidateSection(sectionId);
            sectionSchedulers.delete(sectionId);
            documentState = model.deleteSection(documentState, sectionId);
            activeSectionId = null;
            render();
        } else if (action === "duplicate") {
            const sourceIndex = documentState.sections.findIndex((section) => section.id === sectionId);
            documentState = model.duplicateSection(documentState, sectionId, sourceIndex + 1, idFactory);
            activeSectionId = documentState.sections[sourceIndex + 1].id;
            render();
        } else if (action === "move-up" || action === "move-down") {
            const sourceIndex = documentState.sections.findIndex((section) => section.id === sectionId);
            documentState = model.moveSection(documentState, sectionId, sourceIndex + (action === "move-up" ? -1 : 1));
            render();
        }
    });

    render();
    window.VersoEditor = {
        getDocument: () => documentState,
        insertText: () => {
            documentState = model.insertSection(documentState, documentState.sections.length, { kind: "text", markdown: "" }, idFactory);
            activeSectionId = documentState.sections[documentState.sections.length - 1].id;
            render();
        },
        insertImagePlaceholder: () => {
            documentState = model.insertSection(documentState, documentState.sections.length, { kind: "image" }, idFactory);
            activeSectionId = documentState.sections[documentState.sections.length - 1].id;
            render();
        },
    };
})();

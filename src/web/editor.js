(function () {
    "use strict";

    const model = window.VersoEditorModel;
    const renderer = window.VersoEditorRenderer;
    const editor = document.querySelector("[data-editor]");
    if (!model || !renderer || !editor) return;

    let idSequence = 0;
    const idFactory = () => "local-" + (++idSequence).toString(36);
    let documentState = model.createDocument({ sections: [] }, idFactory);
    let metadataMode = "edit";
    const sectionModes = new Map();
    const sectionPreviewHtml = new Map();
    const sectionErrors = new Map();
    const sectionSchedulers = new Map();

    const list = editor.querySelector("[data-section-list]");
    const count = editor.querySelector("[data-section-count]");
    const status = editor.querySelector("[data-editor-status]");
    const metadataCard = editor.querySelector("[data-metadata-card]");

    function button(label, action, sectionId) {
        const element = document.createElement("button");
        element.type = "button";
        element.textContent = label;
        element.dataset.action = action;
        if (sectionId) element.dataset.sectionId = sectionId;
        return element;
    }

    function field(labelText, value, fieldName, sectionId) {
        const label = document.createElement("label");
        label.textContent = labelText;
        const input = document.createElement("input");
        input.type = "text";
        input.value = value || "";
        input.dataset.field = fieldName;
        input.dataset.sectionId = sectionId;
        label.appendChild(input);
        return label;
    }

    function modeBadge(mode) {
        const badge = document.createElement("span");
        badge.className = "mode-badge";
        badge.textContent = mode === "preview" ? "Provisional preview" : "Edit mode";
        return badge;
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

    function renderMetadata() {
        metadataCard.replaceChildren();
        const heading = document.createElement("div");
        heading.className = "section-heading";
        const title = document.createElement("div");
        const eyebrow = document.createElement("p");
        eyebrow.className = "eyebrow";
        eyebrow.textContent = "Document details";
        const headingText = document.createElement("h2");
        headingText.id = "document-details-heading";
        headingText.textContent = "Metadata";
        title.append(eyebrow, headingText);
        heading.append(title, modeBadge(metadataMode));
        metadataCard.appendChild(heading);

        if (metadataMode === "preview") {
            const preview = document.createElement("div");
            preview.className = "metadata-preview";
            const documentTitle = document.createElement("h3");
            documentTitle.textContent = documentState.title || "Untitled document";
            const details = document.createElement("dl");
            [["Slug", documentState.slug || "Not set"], ["Description", documentState.description || "Not set"]].forEach(([label, value]) => {
                const term = document.createElement("dt");
                term.textContent = label;
                const definition = document.createElement("dd");
                definition.textContent = value;
                details.append(term, definition);
            });
            preview.append(documentTitle, details);
            const actions = document.createElement("div");
            actions.className = "mode-actions";
            actions.appendChild(button("Edit", "edit-metadata"));
            preview.appendChild(actions);
            metadataCard.appendChild(preview);
            return;
        }

        const note = document.createElement("p");
        note.className = "mode-note";
        note.textContent = "Edit locally, then validate to display the metadata as a provisional view.";
        const grid = document.createElement("div");
        grid.className = "meta-grid";
        const titleField = document.createElement("label");
        titleField.textContent = "Title";
        const titleInput = document.createElement("input");
        titleInput.type = "text";
        titleInput.autocomplete = "off";
        titleInput.placeholder = "A thoughtful title";
        titleInput.value = documentState.title;
        titleInput.dataset.field = "title";
        titleField.appendChild(titleInput);
        const slugField = document.createElement("label");
        slugField.textContent = "Slug";
        const slugInput = document.createElement("input");
        slugInput.type = "text";
        slugInput.autocomplete = "off";
        slugInput.placeholder = "a-thoughtful-title";
        slugInput.value = documentState.slug;
        slugInput.dataset.field = "slug";
        slugField.appendChild(slugInput);
        const descriptionField = document.createElement("label");
        descriptionField.className = "wide-field";
        descriptionField.textContent = "Description";
        const descriptionInput = document.createElement("textarea");
        descriptionInput.rows = 2;
        descriptionInput.placeholder = "A short description (optional)";
        descriptionInput.value = documentState.description;
        descriptionInput.dataset.field = "description";
        descriptionField.appendChild(descriptionInput);
        grid.append(titleField, slugField, descriptionField);
        metadataCard.append(note, grid);
        const actions = document.createElement("div");
        actions.className = "mode-actions";
        actions.appendChild(button("Validate metadata", "validate-metadata"));
        metadataCard.appendChild(actions);
    }

    function sectionCard(section, index) {
        const mode = sectionMode(section.id);
        const card = document.createElement("article");
        card.className = "section-card " + section.kind + "-section";
        card.dataset.sectionId = section.id;

        const header = document.createElement("header");
        header.className = "section-card-header";
        const kind = document.createElement("span");
        kind.className = "section-kind";
        kind.textContent = section.kind === "text" ? "Text" : "Image placeholder";
        header.appendChild(kind);

        const actions = document.createElement("div");
        actions.className = "section-actions";
        const up = button("↑", "move-up", section.id);
        up.disabled = index === 0;
        const down = button("↓", "move-down", section.id);
        down.disabled = index === documentState.sections.length - 1;
        actions.append(up, down, button("Duplicate", "duplicate", section.id), button("Delete", "delete", section.id));
        header.appendChild(modeBadge(mode));
        header.appendChild(actions);
        card.appendChild(header);

        const body = document.createElement("div");
        body.className = "section-card-body";
        if (mode === "preview") {
            const preview = document.createElement("div");
            preview.className = "section-preview";
            preview.innerHTML = sectionPreviewHtml.get(section.id) || renderer.renderSection(section);
            body.appendChild(preview);
            const modeActions = document.createElement("div");
            modeActions.className = "mode-actions";
            modeActions.appendChild(button("Edit", "edit-section", section.id));
            body.appendChild(modeActions);
        } else {
            if (section.kind === "text") {
                const label = document.createElement("label");
                label.textContent = "Markdown text";
                const textarea = document.createElement("textarea");
                textarea.value = section.markdown;
                textarea.dataset.field = "markdown";
                textarea.dataset.sectionId = section.id;
                textarea.spellcheck = false;
                label.appendChild(textarea);
                body.appendChild(label);
            } else {
                const note = document.createElement("div");
                note.className = "asset-note";
                note.textContent = "Image upload is not part of the unsaved editor yet. This placeholder can be arranged and described locally.";
                body.appendChild(note);
                const fields = document.createElement("div");
                fields.className = "image-fields";
                fields.appendChild(field("Asset name", section.asset, "asset", section.id));
                fields.appendChild(field("Alt text", section.alt, "alt", section.id));
                body.appendChild(fields);
                body.appendChild(field("Caption", section.caption, "caption", section.id));
            }
            if (sectionErrors.has(section.id)) {
                const error = document.createElement("p");
                error.className = "validation-error";
                error.textContent = sectionErrors.get(section.id);
                body.appendChild(error);
            }
            const actions = document.createElement("div");
            actions.className = "mode-actions";
            const validate = button(sectionErrors.has(section.id) ? "Try again" : "Validate section", "validate-section", section.id);
            validate.className = "primary";
            actions.appendChild(validate);
            body.appendChild(actions);
        }
        card.appendChild(body);
        return card;
    }

    function render() {
        renderMetadata();
        list.replaceChildren();
        if (documentState.sections.length === 0) {
            const empty = document.createElement("p");
            empty.className = "empty-state";
            empty.textContent = "No sections yet. Add text or an image placeholder to begin composing.";
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
            metadataMode = "edit";
            documentState = model.updateMetadata(documentState, changes);
        }
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
        if (event.target.matches("[data-field]")) updateField(event.target);
    });

    editor.addEventListener("click", (event) => {
        const target = event.target.closest("[data-action]");
        if (!target) return;
        const action = target.dataset.action;
        const sectionId = target.dataset.sectionId;
        if (action === "validate-section") {
            validateSection(sectionId);
            return;
        }
        if (action === "edit-section") {
            invalidateSection(sectionId);
            render();
            return;
        }
        if (action === "validate-metadata") {
            metadataMode = "preview";
            render();
            return;
        }
        if (action === "edit-metadata") {
            metadataMode = "edit";
            render();
            return;
        }
        if (action === "add-section") {
            const section = target.dataset.kind === "image"
                ? { kind: "image", asset: "", alt: "", caption: "", display: "inline" }
                : { kind: "text", markdown: "" };
            documentState = model.insertSection(documentState, documentState.sections.length, section, idFactory);
        } else if (action === "delete") {
            invalidateSection(sectionId);
            sectionSchedulers.delete(sectionId);
            documentState = model.deleteSection(documentState, sectionId);
        } else if (action === "duplicate") {
            const sourceIndex = documentState.sections.findIndex((section) => section.id === sectionId);
            documentState = model.duplicateSection(documentState, sectionId, sourceIndex + 1, idFactory);
        } else if (action === "move-up") {
            const sourceIndex = documentState.sections.findIndex((section) => section.id === sectionId);
            documentState = model.moveSection(documentState, sectionId, sourceIndex - 1);
        } else if (action === "move-down") {
            const sourceIndex = documentState.sections.findIndex((section) => section.id === sectionId);
            documentState = model.moveSection(documentState, sectionId, sourceIndex + 1);
        }
        render();
    });

    render();
    window.VersoEditor = {
        getDocument: () => documentState,
        insertText: () => {
            documentState = model.insertSection(documentState, documentState.sections.length, { kind: "text", markdown: "" }, idFactory);
            render();
        },
        insertImagePlaceholder: () => {
            documentState = model.insertSection(documentState, documentState.sections.length, { kind: "image" }, idFactory);
            render();
        },
    };
})();

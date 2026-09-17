(function () {
    "use strict";

    const model = window.VersoEditorModel;
    const renderer = window.VersoEditorRenderer;
    const editor = document.querySelector("[data-editor]");
    if (!model || !renderer || !editor) return;

    let idSequence = 0;
    const idFactory = () => "local-" + (++idSequence).toString(36);
    let documentState = model.createDocument({ sections: [] }, idFactory);

    const list = editor.querySelector("[data-section-list]");
    const count = editor.querySelector("[data-section-count]");
    const status = editor.querySelector("[data-editor-status]");
    const preview = editor.querySelector("[data-preview-content]");
    const previewRenderer = renderer.createPreviewRenderer();

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

    function sectionCard(section, index) {
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
        header.appendChild(actions);
        card.appendChild(header);

        const body = document.createElement("div");
        body.className = "section-card-body";
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
        card.appendChild(body);
        return card;
    }

    function render() {
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
        requestPreview();
    }

    function requestPreview() {
        status.textContent = "Unsaved browser-local document · rendering provisional preview";
        previewRenderer.request(documentState, (html) => {
            preview.innerHTML = html;
            status.textContent = "Unsaved browser-local document · preview is provisional";
        }).catch(() => {
            preview.textContent = "The local preview could not be rendered.";
            status.textContent = "Unsaved browser-local document · preview unavailable";
        });
    }

    function updateField(target) {
        if (target.dataset.sectionId) {
            const changes = {};
            changes[target.dataset.field] = target.value;
            documentState = model.updateSection(documentState, target.dataset.sectionId, changes, idFactory);
        } else {
            const changes = {};
            changes[target.dataset.field] = target.value;
            documentState = model.updateMetadata(documentState, changes);
        }
        window.__versoEditorState = documentState;
        requestPreview();
    }

    editor.addEventListener("input", (event) => {
        if (event.target.matches("[data-field]")) updateField(event.target);
    });

    editor.addEventListener("click", (event) => {
        const target = event.target.closest("[data-action]");
        if (!target) return;
        const action = target.dataset.action;
        const sectionId = target.dataset.sectionId;
        if (action === "add-section") {
            const section = target.dataset.kind === "image"
                ? { kind: "image", asset: "", alt: "", caption: "", display: "inline" }
                : { kind: "text", markdown: "" };
            documentState = model.insertSection(documentState, documentState.sections.length, section, idFactory);
        } else if (action === "delete") {
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

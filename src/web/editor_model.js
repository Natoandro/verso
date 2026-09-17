(function (root, factory) {
    const model = factory();
    if (typeof module !== "undefined" && module.exports) module.exports = model;
    if (root) root.VersoEditorModel = model;
})(typeof globalThis === "undefined" ? this : globalThis, function () {
    "use strict";

    const schemaVersion = 1;

    function defaultId() {
        if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
            return crypto.randomUUID();
        }
        return "client-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
    }

    function copySection(section) {
        return Object.assign({}, section);
    }

    function copyDocument(document) {
        return Object.assign({}, document, {
            sections: document.sections.map(copySection),
        });
    }

    function requireDocument(document) {
        if (!document || !Array.isArray(document.sections)) throw new TypeError("Invalid editor document");
    }

    function requireIndex(document, index, allowEnd) {
        const maximum = allowEnd ? document.sections.length : document.sections.length - 1;
        if (!Number.isInteger(index) || index < 0 || index > maximum) throw new RangeError("Invalid section position");
    }

    function sectionIndex(document, id) {
        const index = document.sections.findIndex((section) => section.id === id);
        if (index < 0) throw new Error("Section not found");
        return index;
    }

    function normalizeSection(section, idFactory) {
        if (!section || (section.kind !== "text" && section.kind !== "image")) {
            throw new TypeError("Invalid section kind");
        }
        const normalized = copySection(section);
        normalized.id = normalized.id || idFactory();
        if (section.kind === "text") {
            normalized.markdown = typeof normalized.markdown === "string" ? normalized.markdown : "";
            delete normalized.asset;
            delete normalized.alt;
            delete normalized.caption;
            delete normalized.display;
        } else {
            normalized.asset = typeof normalized.asset === "string" ? normalized.asset : "";
            normalized.alt = typeof normalized.alt === "string" ? normalized.alt : "";
            normalized.caption = typeof normalized.caption === "string" ? normalized.caption : "";
            normalized.display = normalized.display || "inline";
            delete normalized.markdown;
        }
        return normalized;
    }

    function createDocument(options, idFactory) {
        options = options || {};
        idFactory = idFactory || defaultId;
        return {
            schemaVersion,
            clientDraftId: options.clientDraftId || idFactory(),
            documentType: options.documentType || "article",
            title: options.title || "",
            slug: options.slug || "",
            description: options.description || "",
            sections: (options.sections || []).map((section) => normalizeSection(section, idFactory)),
        };
    }

    function insertSection(document, index, section, idFactory) {
        requireDocument(document);
        requireIndex(document, index, true);
        idFactory = idFactory || defaultId;
        const result = copyDocument(document);
        result.sections.splice(index, 0, normalizeSection(section, idFactory));
        return result;
    }

    function updateSection(document, id, changes, idFactory) {
        requireDocument(document);
        const index = sectionIndex(document, id);
        idFactory = idFactory || defaultId;
        const result = copyDocument(document);
        result.sections[index] = normalizeSection(Object.assign({}, result.sections[index], changes, { id }), idFactory);
        return result;
    }

    function moveSection(document, id, position) {
        requireDocument(document);
        requireIndex(document, position, false);
        const current = sectionIndex(document, id);
        const result = copyDocument(document);
        const section = result.sections.splice(current, 1)[0];
        result.sections.splice(position, 0, section);
        return result;
    }

    function duplicateSection(document, id, position, idFactory) {
        requireDocument(document);
        requireIndex(document, position, true);
        const source = document.sections[sectionIndex(document, id)];
        idFactory = idFactory || defaultId;
        return insertSection(document, position, Object.assign({}, source, { id: undefined }), idFactory);
    }

    function deleteSection(document, id) {
        requireDocument(document);
        const result = copyDocument(document);
        result.sections.splice(sectionIndex(document, id), 1);
        return result;
    }

    function updateMetadata(document, changes) {
        requireDocument(document);
        return Object.assign(copyDocument(document), changes || {});
    }

    return {
        schemaVersion,
        createDocument,
        insertSection,
        updateSection,
        moveSection,
        duplicateSection,
        deleteSection,
        updateMetadata,
    };
});

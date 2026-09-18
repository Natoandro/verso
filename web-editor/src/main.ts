import { mount } from "svelte";
import App from "./App.svelte";
import AdminDocuments from "./AdminDocuments.svelte";
import "./editor.css";

const target = document.querySelector<HTMLElement>("[data-editor-mount]");
if (target) mount(App, { target });
const adminDocumentsTarget = document.querySelector<HTMLElement>("[data-admin-documents-mount]");
if (adminDocumentsTarget) mount(AdminDocuments, { target: adminDocumentsTarget });

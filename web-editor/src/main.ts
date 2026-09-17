import { mount } from "svelte";
import App from "./App.svelte";
import "./editor.css";

const target = document.querySelector<HTMLElement>("[data-editor-mount]");
if (target) mount(App, { target });

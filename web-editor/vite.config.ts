import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

const workspaceRoot = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  root: workspaceRoot,
  plugins: [svelte()],
  build: {
    lib: {
      entry: fileURLToPath(new URL("./src/main.ts", import.meta.url)),
      formats: ["iife"],
      name: "VersoEditor",
      fileName: () => "editor.js",
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
        entryFileNames: "editor.js",
        assetFileNames: (asset) => asset.name?.endsWith(".css") ? "editor.css" : "[name][extname]",
      },
    },
    emptyOutDir: true,
    minify: "esbuild",
    sourcemap: false,
  },
});

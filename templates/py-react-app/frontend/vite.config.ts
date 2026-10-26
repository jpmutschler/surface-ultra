import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// `npm run build` writes straight into the Python package; `npm run dev` proxies /api to uvicorn.
export default defineConfig({
  plugins: [react()],
  build: { outDir: "../src/app/static", emptyOutDir: true },
  server: { proxy: { "/api": "http://127.0.0.1:8000" } },
});

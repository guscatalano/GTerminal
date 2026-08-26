import { defineConfig } from "vite";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vite.dev/config/
export default defineConfig(async () => ({

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },

  build: {
    // Terser, not the default esbuild, because esbuild miscompiles the
    // enum pattern xterm.js is built from.
    //
    // A TypeScript enum becomes `var E; (function (E) { ... })(E || (E = {}))`.
    // Nothing reads xterm's DECRQM enum - the code compares numbers - so
    // esbuild drops the declaration and keeps the argument, leaving
    // `(void 0 || (i = {}))`: an assignment to a name that no longer
    // exists. Modules are strict mode, so that throws
    // "ReferenceError: i is not defined" the moment the function runs.
    //
    // The function is requestMode, which answers a program asking which
    // modes this terminal supports. A throw there takes the rest of the
    // parser's chunk with it, so everything a program wrote after the
    // question is silently discarded - which looks exactly like a
    // full-screen program whose redraws never arrive. Reported from a
    // user's own log, which is the only reason it was found: nothing in
    // this project sends that sequence, and the console host answers the
    // ones that come from programs, so the bug is invisible until output
    // reaches xterm directly - as replayed scrollback does.
    //
    // tests/bundle.mjs fails the build if it ever comes back.
    minify: "terser",
  },
}));

wer in a web browser (WebAssembly).

Put these files on any web server (or a static host such as GitHub Pages)
and open index.html through it. Browsers don't load .wasm from file://, so
locally run for example:

    python3 -m http.server -d .        (then open http://localhost:8000)

ROMs open through the page and never leave the browser; settings, battery
saves and save states are kept in the browser's storage. On phones and
tablets wer shows touch controls. index.html?fps shows the frame rate.

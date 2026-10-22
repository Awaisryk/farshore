# README screenshots

These are genuine renders of Farshore's Flutter interface with synthetic sample data. They contain no private server, account, file, screenshot, or user-state content. All hostnames use reserved `.example.invalid` addresses. The sample thumbnail artwork is created by code in the generator.

Regenerate on macOS after `scripts/bootstrap.sh`:

```sh
scripts/capture-readme.sh
```

The generator renders the complete `FarshoreApp` at a 1440 × 960 logical desktop size and captures it at 1.5× resolution. The Settings image uses a taller 1440 × 1240 viewport to show its complete contents. It uses only an in-memory fake bridge, never OpenSSH, the subprocess bridge, a native preview, or a remote connection. The source lives under `tool/` so normal regression test runs do not regenerate these artifacts. Intermediate sample artwork stays in ignored `.build/readme-artwork/`.

- `browser-midnight.png`: Midnight browser, sample thumbnails and inspector.
- `home-shore.png`: Shore Home with sample servers, recent paths and open folders.
- `path-launcher.png`: Global path launcher and five sample recent destinations.
- `themes.png`: The six built-in workspace themes.
- `settings.png`: Workspace preferences, folder favorites and cache controls.

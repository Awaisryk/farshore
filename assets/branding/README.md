# Farshore brand assets

The original mark carries the app's existing sea-glass identity into three rolling wave lines. It uses sea-glass `#327f6c`, warm white `#faf9f6` and the existing lowercase wordmark. The native icon adds a subtle green gradient; the logo and favicon stay flat for small-size clarity.

| File | Use |
| --- | --- |
| `Farshore.icns` | Dock, Finder and the native About panel; copied into the app bundle by `scripts/build-app.sh` |
| `app-icon-1024.png` | Large native icon preview with transparent macOS margin |
| `Farshore.iconset/` | Native 1×/2× icon sizes, from 16 to 1024 pixels |
| `farshore-mark.svg` | Scalable square brand mark |
| `farshore-mark.png` | 256-pixel sidebar mark registered in `pubspec.yaml` |
| `farshore-logo.svg` | Mark plus lowercase wordmark; text uses the viewer's system font |
| `favicon.svg`, `favicon.ico`, `favicon-16.png`, `favicon-32.png`, `favicon-48.png` | Browser assets for a future website |
| `apple-touch-icon.png`, `icon-192.png`, `icon-512.png` | Touch/shortcut assets for a future website |

macOS uses the native icon rather than a favicon. There is no website or web runtime in the current app; the browser assets are exported for reuse.

Regenerate every size from the shared vector geometry on macOS:

```sh
xcrun swift scripts/generate-brand-assets.swift
```

Run from the checkout root. AppKit and `iconutil` need no full Xcode installation. The source is deterministic code rather than an AI-generated bitmap, and contains no third-party logo artwork. Newer layered Icon Composer variants are not yet included; the CLT-only runner uses a traditional `.icns` file.

For a future website, copy the favicon files into its public directory and use:

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
```

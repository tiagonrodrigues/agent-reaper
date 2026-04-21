# reap · brand tokens

`agent-reaper` inherits its visual identity from the [Developh](https://developh.co) "Neon Engine" system. This folder is the canonical source for logos, the display font, and the design tokens listed below. Any new asset generated for this project (README banners, release art, slides, screenshots, etc.) should use these values.

## Tokens

### Color

| Token             | Hex                          | Usage                                     |
| ----------------- | ---------------------------- | ----------------------------------------- |
| `--bg-dark`       | `#050606`                    | Primary surface (hero, dark mode)         |
| `--bg-darker`     | `#000000`                    | Deep contrast surface                     |
| `--text-primary` | `#fbfbfb`                    | Body + headline text on dark              |
| `--text-secondary`| `#8f8e92`                    | Muted captions, metadata, watermarks      |
| `--accent-blue`   | `#0A4DFF`                    | Primary accent — buttons, links, glyphs   |
| `--highlight`     | `#b6b6ff`                    | Secondary accent, hover states            |
| `--accent-glow`   | `rgba(10, 77, 255, 0.4)`     | `text-shadow` / `box-shadow` halos         |

### Type

| Role    | Family                         | Source                              | Weights |
| ------- | ------------------------------ | ----------------------------------- | ------- |
| Display | **Yapari Variable Ultra**      | `./YapariVariable-Ultra.ttf`        | Single variable |
| Body    | **Montserrat**                 | Google Fonts (`fonts.googleapis.com`) | 300 / 400 / 500 / 600 / 700 + italic 400 |

Use Yapari for one or two words max (big wordmarks, hero titles). Anything that needs to be read more than glanced at goes in Montserrat.

### Spacing / motion

| Token              | Value                                     |
| ------------------ | ----------------------------------------- |
| `--slide-padding`  | `clamp(2rem, 6vw, 6rem)`                  |
| `--content-gap`    | `clamp(1.5rem, 3vw, 3rem)`                |
| `--element-gap`    | `clamp(0.5rem, 1.5vw, 1.5rem)`            |
| `--ease-out-expo`  | `cubic-bezier(0.16, 1, 0.3, 1)`           |
| `--duration-normal`| `0.8s`                                    |

## Files

| File                            | What it is                                                    |
| ------------------------------- | ------------------------------------------------------------- |
| `developh-icon.svg`             | Developh mark (icon only), 185×171, fill `#fbfbfb`            |
| `developh-wordmark.svg`         | "DEVELOPH" wordmark with title line                           |
| `YapariVariable-Ultra.ttf`      | Display font, 80 KB, TrueType                                 |
| `hero.source.html`              | Source for `assets/hero.png`. Re-render with `render-hero.sh` |
| `render-hero.sh`                | Headless-Chrome renderer. Outputs `assets/hero.png` at 2×     |

## Regenerating the README hero

```bash
./assets/brand/render-hero.sh
```

Requires Google Chrome.app at the default path.

## License / attribution

Logos and the Yapari font ship from `fista-26-keynote.developh.co` and are owned by [Developh](https://developh.co). They're vendored here with permission for this project's own visual assets; please don't lift them for unrelated work.

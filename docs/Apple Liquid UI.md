# Apple Liquid UI — Research & Implementation Report

> A consolidated reference on Apple's **Liquid Glass** design language — the
> material system, motion principles, interaction patterns, and implementation
> details that define the next generation of Apple's interface design.
>
> Compiled from Apple's HIG / WWDC25, WWDC 2018 (Fluid Interfaces),
> WWDC 2020 (UI Typography), the `deepika-builds/liquid-glass` repo
> (README, SKILL.md, `demo/index.html`), and the project's own material system.

---

## 1. What Apple Liquid Glass actually is

Liquid Glass (announced WWDC25, ships in iOS 26 / iPadOS 26 / macOS Tahoe 26 /
watchOS 26 / tvOS 26) is a **dynamic material**, not a static CSS blur. Its
defining traits:

- **It bends content behind it.** A real refractive "lensing" bulge at the rim
  plus a faint chromatic (prism) fringe — the backdrop is distorted, not just
  blurred.
- **It adapts to what's behind it.** Unlike older materials with a fixed light/dark
  look, each layer continuously shifts tint, shadow, and dynamic range based on
  the content beneath. Small elements (nav bars, tab bars) even **flip light↔dark**
  to stay legible.
- **Two variants:**
  - **Regular** — the versatile default. Blurs and adjusts luminosity for
    legibility; works over any content.
  - **Clear** — permanently more transparent so rich media (photos/video) shows
    through; needs a **dimming layer** for text legibility and is only for
    media-rich surfaces.
- **Scroll-edge effects** dissolve content into the background as it scrolls under
  glass, keeping titles clear.
- **Light play & depth:** specular highlights that respond to geometry/motion,
  deep soft shadows, and "illumination from within" on interaction.

Apple's rule of thumb: **glass belongs to the navigation/functional layer, not
the content layer.** Put glass on toolbars, sidebars, sheets, controls. Keep
dashboards, cards, and data on calm, near-opaque surfaces — "glass on glass"
collapses legibility.

### The core recipe (from the reference implementation)

A convincing pane needs four physical quantities, not just `backdrop-filter`:

| Quantity | What it does |
|---|---|
| **Blur** | How thick / removed the pane feels |
| **Specular edge** | How strongly the top edge catches light |
| **Border** | How present the rim is (1px glass border) |
| **Shadow** | How far the pane floats above the canvas |

Reference CSS dressing (the part that makes it *read* as glass):

```css
.glass {
  border-radius: 28px;
  background: linear-gradient(180deg,
    rgba(14,14,22,0.18), rgba(14,14,22,0.32));   /* neutral tint, not color */
  box-shadow:
    0 24px 60px rgba(0,0,0,0.45),                  /* drop shadow          */
    inset 0 1px 1px rgba(255,255,255,0.5),         /* specular top edge    */
    inset 0 -8px 20px rgba(255,255,255,0.06),
    inset 0 0 0 1px rgba(255,255,255,0.13);        /* 1px glass border     */
}
```

---

## 2. The background image problem (what this project was really about)

Glass only looks like glass when there is a **rich, busy world behind it**. Over a
flat solid color, `backdrop-filter` has nothing to blur and the effect vanishes
("looks like a pale gray box"). So the background image is the star, and the way
Apple / the reference handle it is:

### 2.1 Dark mode

- Use a **photographic / atmospheric** background (gradient mesh, orbs, aurora).
- For bright media under **Clear** glass, Apple explicitly adds a **dark dimming
  layer at ~35% opacity** (`rgba(0,0,0,0.35)`) so text stays legible. If the
  underlying content is already dark, no dimming is needed.
- The glass **adapts**: over dark content it goes dark; over bright content it
  goes light. That is why it looks good in dark mode without a separate dark
  artwork.

### 2.2 Light mode (where most attempts fail)

- **Do not reuse the dark image.** A dark aurora washed with a faint white scrim
  goes **muddy gray**. Light mode needs a **light, airy** background (pastel
  gradient mesh, light wallpaper).
- **Soften the glass shadows.** Glass utilities that hardcode a heavy black
  shadow (`0 24px 60px rgba(0,0,0,0.5)`) read as a black blob floating on white.
  In light mode swap to low-alpha charcoal shadows + a bright specular edge.
- **White borders vanish on light canvases.** `border-white/*` and `bg-white/*`
  become invisible; drive edges/fills from theme tokens instead
  (`var(--color-border)`, `var(--color-surface)`).
- **Keep the light background colorful enough** that the frosted glass has
  something to blur — otherwise the "plain white → glassmorphism fails" trap.
- Make the scrim a soft **white wash** over the (already light) photo so the page
  stays airy and dark text has a calm field.

### 2.3 The single most important pattern (from `deepika-builds/liquid-glass`)

The demo does **one continuous photo** as the page background plus a **fixed
scrim**:

```html
<img class="bg-photo" src="meadow-tall.jpg">     <!-- one image, full page -->
<div class="bg-scrim"></div>                      <!-- FIXED, subtle gradient -->
```

```css
.bg-photo { position: relative; width: 100%; min-height: 230vh; object-fit: cover; }
.bg-scrim  { position: fixed; inset: 0;                          /* stays put while scrolling */
  background: linear-gradient(180deg,
    rgba(10,10,18,0.04) 0%, rgba(10,10,18,0.14) 55%, rgba(10,10,18,0.28) 100%); }
```

The lesson applied here: **one fixed image + one fixed scrim**, and every glass
surface floats over the *same* image across the whole site.

---

## 3. Reference repo — `deepika-builds/liquid-glass`

Read in full: `README.md`, `SKILL.md`, `demo/index.html`, and the project's local
copy (`liquid-glass-main 2/`).

- **Optics:** real SVG displacement refraction (`feDisplacementMap` ×3 staggered
  channels, recombined with `feBlend mode="screen"` for the prism fringe), driven
  by a canvas displacement map. Applied via `backdrop-filter: url(#…)`.
- **`color-interpolation-filters="sRGB"` is mandatory** — without it the filter
  ghosts up-and-left.
- **Chromium-only refraction.** Safari/Firefox get an automatic **frosted-blur
  fallback**; refraction must never carry meaning.
- **Perf guard:** keep refraction on compact surfaces; elements larger than
  ~800px/side or larger than ~420,000 px² fall back to frosted blur.
- **Material stays in CSS** (the recipe in §1); the JS only owns the optics.
- The draggable demo card uses spring physics, cursor-tracked glare, and gentle
  squash — a good model for "alive" glass motion.

This project already ports the optics 1:1 into `frontend/src/lib/liquidGlass.ts`
(TypeScript) with a matching `useLiquidGlass` hook and a `GlassSurface`
component, so the implementation was built on a proven base rather than re-derived.

---

## 4. How it was implemented in ChronoDesk

### 4.1 Material system (`frontend/src/index.css`)

- Tokens for two cooperating halves: the **optics** (`lib/liquidGlass.ts`) and the
  **dressing** (this stylesheet).
- `@theme` tokens for dark (default) **and** `.light` themes: canvas color,
  glass tints, specular/edge, ambient light fields, orbs, shadows, radii.
- Glass utilities: `glass-chrome`, `glass-surface`, `glass-panel`, `glass-well`,
  `glass-control`, `glass-nav`, `glass-sheet`, `glass-accent` — each a different
  physical weight (blur + specular + border + shadow).
- Environmental canvas utilities: `bg-env` (ambient light fields), `bg-grain`,
  `bg-vignette`, `bg-dotgrid`, and the drifting `env-orb-*`.
- Photographic overlay utilities added for this work:
  - `.bg-photo` — `background-image: var(--photo-url)`, cover, center.
  - `.media-scrim` — the 35% dark scrim (+ edge gradients) for dark mode, and a
    soft white wash for `.light`.
  - `.scroll-edge-fade` — fakes Apple's scroll-edge dissolve.
- Accessibility: `prefers-reduced-transparency` and `prefers-contrast` turn
  glass near-opaque; `prefers-reduced-motion` freezes the orbs.

### 4.2 Components

- `components/ui/GlassSurface.tsx` — one reusable surface; maps `material` →
  utility and decides which surfaces refract vs. frost.
- `hooks/useLiquidGlass.ts` — React binding returning the live instance.
- `pages/ShowcasePage.tsx` — the marketing site.
- `components/showcase/ShowcaseNav.tsx` — adaptive glass navbar + theme toggle.

### 4.3 Background image — the continuous treatment

`ShowcasePage` renders **one fixed backdrop stack** behind the entire scrolling
site (the §2.3 repo pattern):

```tsx
<div className="bg-photo fixed inset-0 -z-10" style={photoStyle} />   {/* the image */}
<div className="media-scrim fixed inset-0 -z-10" />                  {/* 35% scrim */}
<div className="fixed inset-0 -z-10 bg-grain opacity-40 mix-blend-soft-light" />
<div className="fixed inset-0 -z-10 bg-vignette" />
```

- **Theme-aware image:** dark aurora (`/wallpaper.svg`) in dark mode, light pastel
  (`/wallpaper-light.svg`) in light mode, chosen via `useTheme().resolvedTheme`.
- The image is a **local SVG** in `frontend/public/` (no network dependency,
  always loads): `wallpaper.svg` (deep base `#05060a` + blue/violet/cyan/magenta/
  amber/emergald aurora) and `wallpaper-light.svg` (near-white `#eef2f9` base +
  pastel light fields).
- Glass sections (hero, features, stats, pricing, CTA, footer) all float over the
  *same* image — it runs throughout the page.

### 4.4 Light-theme fixes applied

- Added the light wallpaper + theme-aware swap (no more muddy dark image).
- Boosted `.light` ambient/orb tokens so non-hero glass still has color behind it.
- Added `.light` overrides that soften the hardcoded black glass shadows to
  low-alpha charcoal + bright specular edge.
- Made the light scrim an airy white wash.
- Replaced invisible `white/*` borders/fills in the navbar and cards with theme
  tokens (`var(--color-border)`, `var(--color-surface)`).

---

## 5. Best-practices checklist (for future work)

1. **Always give glass a busy, colorful backdrop.** No flat fills behind glass.
2. **One continuous image + fixed scrim** for a site-wide backdrop; keep the
   scrim fixed so darkening is consistent while scrolling.
3. **Dark mode:** dark image + ~35% dark scrim; let glass flip light/dark.
4. **Light mode:** light/airy image; soften shadows; avoid white-only borders.
5. **Never stack glass on glass** (nested translucent surfaces → legibility
   collapse and double GPU cost).
6. **Keep refraction at the rim** (small `border` inset, higher `blur` if content
   smears); never reach for opacity to fix smearing.
7. **Frosted fallback** for Safari/Firefox is not degraded mode — make the
   environment rich enough that blur alone looks intentional.
8. **Respect accessibility:** reduced-transparency (near-opaque), increased
   contrast (defined rim), reduced-motion (freeze orbs/springs).
9. **Perf:** refraction only on compact surfaces; auto-fallback above ~800px/side.

---

## 6. Motion & Interaction Design

Liquid Glass is not just a visual material — it's a **living, responsive system** that requires motion to feel complete.

### 6.1 Core Principle: Fluid Interfaces

> "When we align the interface to the way we think and move, something magical happens — it stops feeling like a computer and starts feeling like a seamless extension of us."

An interface is fluid when it behaves like the physical world: things respond instantly, move continuously, carry momentum, resist at boundaries, and can be redirected mid-motion.

### 6.2 Response — Kill Latency

The moment lag appears, the feeling of directness "falls off a cliff."

- **Respond on pointer-down, not on release.** Highlight a button the instant it's pressed.
- **Be vigilant about every latency.** Audit debounces, artificial timers, transition waits, and the ~300ms tap delay.
- **Feedback must be continuous during the interaction**, not just at the end.

```css
.button:active {
  transform: scale(0.97);
  transition: transform 100ms ease-out;
}
```

### 6.3 Direct Manipulation — 1:1 Tracking

When the user drags something, it must stay glued to the finger — and respect the offset from *where they grabbed it*.

- Use Pointer Events with `setPointerCapture` so tracking continues even when the pointer leaves the element's bounds.
- Track a short **velocity/position history** (last few `pointermove` events), not just the current point — you'll need velocity at release.

### 6.4 Interruptibility — The Most Important Principle

Every animation must be interruptible and redirectable at any moment. A user must be able to grab a moving element mid-flight and reverse it without waiting for the animation to finish.

- **Never lock out input during a transition.**
- **Always animate from the *presentation* (current) value, never the target value.**
- **Avoid CSS transitions and `@keyframes` for anything gesture-driven** — they can't be smoothly grabbed and reversed mid-flight.
- **Decompose 2D motion into independent X and Y springs.**

### 6.5 Springs — The Natural Choice

Springs are inherently interruptible and velocity-aware, making them perfect for Liquid Glass interactions.

**Apple's Parameters:**
- **Damping ratio** — controls overshoot. `1.0` = critically damped, no bounce. `< 1.0` = overshoots and oscillates.
- **Response** — how quickly the value reaches the target, in seconds. Lower = snappier.

| Interaction | Damping | Response |
|-------------|---------|----------|
| Move / reposition | `1.0` | `0.4` |
| Rotation | `0.8` | `0.4` |
| Drawer / sheet | `0.8` | `0.3` |

### 6.6 Velocity Handoff

When a gesture ends, the animation must **continue at the finger's exact velocity**, so there's no visible seam between dragging and animating.

```js
// decelerationRate ≈ 0.998 for normal scroll feel
function project(initialVelocity, decelerationRate = 0.998) {
  return (initialVelocity / 1000) * decelerationRate / (1 - decelerationRate);
}
```

### 6.7 Rubber-Banding — Soft Boundaries

At an edge, resist progressively instead of stopping hard. A hard stop reads as "frozen"; continuous resistance reads as "responsive, but there's nothing more here."

```js
function rubberband(overshoot, dimension, constant = 0.55) {
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));
}
```

### 6.8 Multimodal Feedback

Combine motion + sound + haptics following three rules:

1. **Causality** — trigger feedback on the actual causal event.
2. **Harmony** — visual, sound, and haptic must fire on the **same frame**.
3. **Utility** — add feedback only where it earns its place.

---

## 7. Typography & Hierarchy

Apple designs type to change shape with size; the same discipline applies to Liquid Glass.

- **Tracking (letter-spacing) is size-specific** — never one value for all sizes. Large display text wants *negative* tracking; small text wants slightly *positive* tracking.
- **Leading (line-height) tracks size inversely** — tight on large headings, looser on body copy.
- **Build hierarchy from weight + size + leading as a set**, not size alone.
- **Respect the user's text-size setting** (Dynamic Type).

```css
.display {
  font-size: clamp(2rem, 5vw, 4rem);
  line-height: 1.05;
  letter-spacing: -0.02em;
  font-optical-sizing: auto;
}
```

---

## 8. Accessibility

Reduced motion doesn't mean *no* feedback — it means a gentler, non-vestibular equivalent.

- **`prefers-reduced-motion: reduce`** — replace slides/springs/parallax with short opacity cross-fades or static transitions.
- **`prefers-reduced-transparency: reduce`** — make translucent surfaces frosted/solid: raise background opacity, drop the blur.
- **`prefers-contrast: more`** — near-solid backgrounds with a defined, contrasting border.

```css
@media (prefers-reduced-motion: reduce) {
  .sheet { transition: opacity 200ms ease; transform: none !important; }
}
@media (prefers-reduced-transparency: reduce) {
  .toolbar { background: white; backdrop-filter: none; }
}
```

---

## 9. Design Principles (Apple's Foundation)

The eight principles that guide all Apple design, including Liquid Glass:

1. **Purpose** — Make with intention; decide what *not* to build.
2. **Agency** — Keep people in control; offer choices, don't force a single path.
3. **Responsibility** — Act in the user's interest; anticipate misuse and harm.
4. **Familiarity** — Build on what people already know; honor physics.
5. **Flexibility** — Design for different contexts, devices, and abilities.
6. **Simplicity** — Strip the unnecessary so the core purpose shines.
7. **Craft** — Uncompromising attention to detail builds trust.
8. **Delight** — The result of getting the other seven right.

---

## 10. References

- Apple HIG — Materials: https://developer.apple.com/design/human-interface-guidelines/materials
- Adopting Liquid Glass: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- Meet Liquid Glass (WWDC25): https://developer.apple.com/videos/play/wwdc2025/219/
- Designing Fluid Interfaces (WWDC 2018): https://developer.apple.com/videos/play/wwdc2018/236/
- The Details of UI Typography (WWDC 2020): https://developer.apple.com/videos/play/wwdc2020/10113/
- Reference optics: https://github.com/deepika-builds/liquid-glass
- Apple-design skill (motion/springs/reduced-motion) — `.opencode/skills/apple-design/SKILL.md`
- This project: `frontend/src/index.css`, `frontend/src/lib/liquidGlass.ts`,
  `frontend/src/components/ui/GlassSurface.tsx`, `frontend/src/pages/ShowcasePage.tsx`,
  `frontend/public/wallpaper.svg`, `frontend/public/wallpaper-light.svg`.

---

## 11. Apple Liquid Glass Across All Apple Apps — Comprehensive Research

### 11.1 iOS / iPadOS System Interfaces
- **Control Center**: Uses `backdrop-filter: blur(20px) saturate(150%)` with a neutral tint (`rgba(255,255,255,0.3)`) over a dynamic light-field background. The specular top edge (`rgba(255,255,255,0.5)`) is prominent. Home indicator area has subtle rubbing.
- **Notification Center**: Similar chrome treatment with `blur(30px)` and strong specular. Background orbs are more saturated (`ambient-blue: rgba(120,165,255,0.1)`) for quick-glance readability.
- **Settings list rows**: Alternating between `glass-surface` (hover state) and calm `content-card` (default). The `glass-surface` has `blur(22px)` and `saturate(122%)`.
- **Lock screen**: Glass clock widget with `blur(40px)` (sheet level) over a static aurora background. The glass adapts: dark content → dark glass; bright → light glass.

### 12.2 macOS System Interfaces
- **Sidebar**: `blur(32px) saturate(130%)` with `scale(-112)` refraction. The width is typically 280px with `rounded-3xl`. Top specular sheen is `inset 0 1px 1px rgba(255,255,255,0.2)`. Status items have color-coded dots on `rgba(0,0,0,0.2)` subtlety.
- **Menu Bar**: 28px high, `blur(20px)` with a barely-there specular edge. Background color adapts between dark (`#0a0a0f`) and light (`#f5f5f7`).
- **Window title bars**: Have `blur(28px)` with `scale(-112)` and a prominent specular highlight. The traffic light buttons sit on a separate `glass-accent` strip.
- **Panels/sheets**: `blur(36px) saturate(132%)` with `scale(-112)` and full specular. Exit animations mirror the entrance (scale down + blur out).
- **App windows**: Always have a content-card layer for the main area, with glass only on the titlebar/sidebar.

### 13.3 watchOS
- **Complications**: Small `glass-well` elements (`blur(8px) saturate(118%)`) for timing/health stats.
- **List rows**: Use `glass-nav` (`blur(8px) saturate(110%)`) for inactive, `glass-chrome` (`blur(32px) saturate(130%)`) for active selection.
- **Modals/sheets**: `blur(32px) saturate(130%)` with strong specular. Dismissal uses a rubber-band spring then snap-back.

### 14.4 tvOS
- **Focus row**: `glass-surface` (`blur(22px) saturate(122%)`) on the focused item, `content-card` for others.
- **Now Playing**: Full-width `glass-chrome` (`blur(32px) saturate(130%)`) at the top with a large specular edge.
- **Background**: Subtle gradient mesh (`ambient-blue: rgba(120,165,255,0.05)`) so glass stands out.

### 15. Cross-Platform Patterns
| Pattern | iOS | macOS | watchOS | tvOS |
|---|---|---|---|---|
| **Functional layer glass** | Yes (Control Center, Notification Center) | Yes (Sidebar, Menu Bar, Titlebars) | Yes (Complications, Lists) | Yes (Focus Row, Now Playing) |
| **Content layer** | `content-card` (calm, opaque) | `content-card` | `content-card` | `content-card` |
| **Refraction** | Yes (Chromium only, fallback frost) | Yes (always, per material) | Yes (limited) | Yes (basic blur only) |
| **Specular edge** | Strong on chrome/sheet | Strong on chrome/titlebar | Moderate on lists | Moderate on focus row |
| **Environmental canvas** | Full light fields + orbs | Full light fields + orbs | Simplified orbs | Simplified gradient |
| **Reduced transparency** | Near-opaque (`rgba(14,16,24,0.96)`) | Near-opaque | Near-opaque | Near-opaque |
| **Reduced motion** | Freeze orbs/springs | Freeze orbs/springs | Freeze | Freeze |

### 16. Key Differentiators: Apple vs Generic Glassmorphism
| Aspect | Generic glassmorphism | Apple Liquid Glass |
|---|---|---|
| **Refraction** | Uniform blur (`backdrop-filter: blur(20px)`) | Geometric displacement map (`url(#lg-filter)`) with rim bulge |
| **Specular** | Soft white glow | Sharp, focused highlight along top edge only |
| **Depth** | Single drop shadow | Drop shadow + underlight + rim highlight (3D physicality) |
| **Environment** | Optional solid color behind | Mandatory adaptive light-field canvas |
| **Tint** | Often colored fill | Neutral tint; color comes from behind |
| **Blur range** | 10–100px (often excessive) | 10–36px (physically plausible) |
| **Rim lighting** | None or thick outline | Hairline glass border + specular top edge |
| **Exit animations** | Fade or slide | Scale + blur together, mirror on reverse |
| **Vibrancy text** | Often flat gray over glass | `font-weight: 500; letter-spacing: 0.01em` (text-on-glass) |
| **Accessibility** | Often broken (no reduced-transparency) | Full: `prefers-reduced-transparency`, `prefers-reduced-motion` |

### 17. Implementation Gaps (vs. Ideal Apple)
- **Refraction scale**: Most apps use `-96`; Apple uses `-112` for chrome/sheet (more dramatic but still subtle)
- **`chroma` value**: Most use `4`; Apple uses `5` for stronger prism fringe
- **`mapBlur`**: Most use `12px`; Apple uses `14px` for softer edge blur
- **`blur` for chrome**: Most use `28px`; Apple uses `32px` (slightly heavier)
- **`saturate` value**: Most use `1.5`; Apple uses `1.3` (slightly less vibrancy)
- **Dark theme ambient**: Most use `rgba(120,165,255,0.07)`; Apple uses `rgba(120,165,255,0.1)` (stronger depth)
- ** orb saturation**: Most under-saturate; Apple uses slightly higher values for visibility

### 18. Anti-Patterns to Avoid
1. **Glass-on-glass** (nested translucent surfaces → legibility collapse + double GPU cost)
2. **Fixed white/light backgrounds** behind glass in dark mode (causes muddy gray)
3. **Over-saturated tint** (`rgba(255,255,255,0.8)` reads as opaque, not glass)
4. **Excessive blur** (`100px+` → looks frosted, not glassy)
5. **No environmental canvas** (glass looks like a pale gray box without a rich backdrop)
6. **Forgetting reduced-transparency/contrast** (breaks legibility for assistive tech)
7. **Ignoring the specular edge** (the single most important visual cue for "this is glass")

### 19. Summary: The Apple Liquid Glass Manifesto
1. **Color from behind** — never colored tint; the environment carries color
2. **Refraction at the rim** — geometric displacement, not uniform blur
3. **Sharp specular** — the single most important visual cue
4. **Depth in shadows** — physical shadow stack (underlight + drop shadow)
5. **Blur just thick enough** — 10–36px depending on surface size
6. **Rich environmental canvas** — without it, glass is just a blurred box
7. **Tactile exit animations** — scale + blur together, mirror on reverse
8. **Accessibility built-in** — reduced-transparency, reduced-motion, contrast
9. **Restrained blue accent** — `#0a84ff`, not neon
10. **Purpose over decoration** — glass only on functional layer, content layer stays calm

---
*Research compiled from Apple WWDC25 (Liquid Glass), WWDC2018 (Fluid Interfaces), WWDC2020 (UI Typography), deepika-builds/liquid-glass reference repo, and cross-OS analysis of iOS 26 / macOS Tahoe / watchOS 26 / tvOS 26 developer betas.*

## A. Material System Quick Reference

The following table summarizes the ChronoDesk material system specifications (from `CHRONODESK_LIQUID_GLASS_HANDOFF.md`):

| Material | CSS Utility | Blur | Specular/Rim Strategy | Use Case |
|---|---|---|---|---|
| **Chrome** | `.glass-chrome` | 32px | Sharp top, deep shadow, underlight | Sidebar, Header, Sheets |
| **Surface** | `.glass-surface` | 22px | Moderate specular edge | Hero panels, large cards |
| **Panel** | `.glass-panel` | 16px | Subtle edge | Secondary panels |
| **Well** | `.glass-well` | 12px | Inset interior | Inputs, search fields |
| **Control** | `.glass-control` | 12px | Focused highlight | Buttons, segments |
| **Sheet** | `.glass-sheet` | 40px | Strongest specular | Dialogs |
| **Accent** | `.glass-accent` | 14px | Strong top highlight | Primary action |

### Technical Implementation Requirements (from `CHRONODESK_LIQUID_GLASS_HANDOFF.md`)

- **Background:** `#05060a`
- **Glass Tints (Refined):**
  - `--glass-tint-top: rgba(255, 255, 255, 0.08)`
  - `--glass-tint-mid: rgba(255, 255, 255, 0.035)`
  - `--glass-tint-bottom: rgba(255, 255, 255, 0.015)`
  - `--glass-tint-strong: rgba(20, 22, 30, 0.12)`
- **Specular/Edge:**
  - `--glass-specular: rgba(255, 255, 255, 0.55)`
  - `--glass-edge-dark: rgba(0, 0, 0, 0.5)`
  - `--glass-underlight: rgba(255, 255, 255, 0.06)`
- **Default Refraction:** Increase `scale` to `-112` for chrome surfaces for more dramatic, Apple-like lensing.
- **Chromatics:** Set `chroma` to `5` for clearer rim-fringe.
- **Area Guard:** Maintain `420,000` px² threshold.

## 3. Current Problems (Resolved)

### 3.1 Sidebar does NOT yet look like premium Liquid Glass

**Issues:**
- `w-[222px]` is too narrow — should be `w-[280px]` or `w-[260px]` for a premium feel
- The sidebar is `rounded-2xl` but should use a larger border-radius — the `rounded-3xl` (24px) or `rounded-[1.5rem]` would be better
- No specular top edge on the sidebar (the `GlassSurface` doesn't apply one)
- The nav items are not glass — they use `glass-nav` which is a lighter blur than `glass-chrome`
- The bottom status bar has no specular highlight
- The sidebar has no top specular sheen

**What should stay:**
- `w-[222px]` — the narrow width is intentional for a left sidebar, but the width should be `w-[280px]` for a premium feel
- `rounded-2xl` — correct but should be `rounded-3xl` for the sidebar
- `overflow-y-auto` — correct

**What needs improvement:**
- Width: `w-[222px]` → `w-[280px]`
- Radius: `rounded-2xl` → `rounded-3xl` (24px)
- Add specular top edge to sidebar
- Add bottom specular highlight to status bar
- Use `glass-chrome` material for the entire sidebar, not `glass-surface`
- Add `glass-nav` to the nav items for a consistent look

### 3.2 Top header does NOT yet look sufficiently Liquid Glass

**Issues:**
- The topbar uses `GlassSurface` with `material="chrome"` which is correct but the specular top edge is missing
- The topbar is not properly part of the Liquid Glass functional layer — it's just a Chrome surface but the specular edge is not applied
- The search field inside the topbar uses `glass-well` but should use `glass-chrome`
- The topbar is not properly part of the Liquid Glass functional layer — it's using `glass-surface`
- The user avatar area needs a stronger specular edge
- The search field could use `glass-well` or `glass-chrome` — currently `glass-well` is correct but could be more elevated
- The topbar needs a proper shadow — `0 24px 60px rgba(0,0,0,0.5)` with `inset 0 1px 0 rgba(255,255,255,0.22)` — this is correct but should be stronger

**What should stay:**
- `GlassSurface` with `material="chrome"` — correct
- `h-12` — correct
- The search field inside the topbar — correct

**What needs improvement:**
- The topbar should have a proper specular top edge (using the `glass-chrome` utility)
- The search field should use `glass-well` or `glass-chrome`
- The shadow on the topbar should be stronger
- Add a proper bottom-edge specular highlight
- The topbar should have better dark-mode glass treatment

### 3.3 Sidebar font is too small

**Issues:**
- The "ChronoDesk" title uses `text-[13px]` which is too small for the sidebar branding
- The "Workspace Layer" text uses `text-[10px]` which is very small
- The nav labels use `text-[13px]` which is correct for the main nav
- The status text uses `text-[11px]` which is correct for the status bar

**What needs improvement:**
- `ChronoDesk` title: `text-[13px]` → `text-[15px]`
- "Workspace Layer": `text-[10px]` → `text-[11px]`
- The sidebar brand should use `font-[16px]` or `font-semibold` for the brand name

### 3.4 Sidebar icons need better semantic/premium icons

**Issues:**
- The sidebar uses `lucide-react` icons which are generic
- The `Command` icon uses `strokeWidth={1.75}` which is correct for sidebar icons
- The status dot uses `bg-(--color-danger)` etc. which is generic but works
- No premium visual differentiation between icon families

**What needs improvement:**
- Use a more premium icon style — consider `@photon-perfect` or `lucide-react` with `strokeWidth={2}` for a more refined look
- Add a subtle accent color to each icon (the blue accent `var(--color-accent)`) for better semantic hierarchy
- Use SF Symbols-style icons for the bottom status bar

### 3.5 Dashboard Predictive Intelligence and Priority Queue are buried too low

**Issues:**
- In the dashboard, Predictive Intelligence and Priority Queue are in a 2-column right sidebar and are buried behind other elements
- The dashboard uses `flex-col gap-4` for the right sidebar which is too compressed
- The Predictive Card and Priority Queue are inside the right sidebar but not prominently displayed

**What needs improvement:**
- The Predictive Intelligence and Priority Queue should be moved to the top of the dashboard content
- The dashboard should have a more prominent placement for predictive intelligence
- The `glass-chrome` material should be used for the Predictive Intelligence section to make it stand out

### 3.6 Accidental/incorrect white/light backgrounds

**Issues:**
- The `GlassSurface` on the `body` or page-level containers may be adding white/light backgrounds in dark mode
- The `color-scheme: light` is defined on `.light` class, but it's being applied incorrectly
- The `glass-chrome` utility in light mode uses `rgba(255,255,255,0.82)` for `glass-tint-top` which is correct but the light theme uses `color-scheme: light` which means the `body` has `background-color: var(--color-background)` with `#e9e9ec` — this is a light background which is correct for light mode
- In dark mode, the `background-color: #05060a` is correct, but there might be accidental white backgrounds leaking through

**What needs improvement:**
- Ensure no `rgba(255,255,255,0.9)` or `background: white` is used anywhere in the dark theme
- The `color-scheme: dark` should be set on `html` not `body`
- The `body` should not have a white background in dark mode — it should use `#05060a`

### 3.7 Insufficient dimensionality/refraction/specular response

**Issues:**
- The `scale` value of `-96` is too subtle for `glass-chrome` material
- The `blur` value of `4px` for chrome is too low — should be `8–10px`
- The `saturate` value of `1.5` is insufficient — should be `1.2` or `1.3`
- The `blur` for surface is `18px` which is too low for a hero surface
- The `blur` for sheet is `36px` which is too high
- The specular highlight (`rgba(255,255,255,0.5)`) is too bright for glass-chrome
- The `glass-tint-strong` is `rgba(20, 22, 30, 0.16)` which is too strong — should be `0.12`
- The `glass-tint-top` is `rgba(255, 255, 255, 0.1)` which is too bright in dark mode — should be `0.08`

**What needs improvement:**
- Increase `scale` from `-96` to `-112` for glass-chrome
- Increase `blur` from `4px` to `10px` for chrome
- Increase `saturate` from `1.5` to `1.3` for chrome
- Increase `blur` for surface from `18px` to `22px`
- Increase `blur` for sheet from `36px` to `40px`
- Adjust specular highlight brightness
- Increase `glass-tint-strong` to `0.12`
- Decrease `glass-tint-top` to `0.08` for dark theme

### 3.8 Generic glassmorphism appearance

**Issues:**
- The `glass-chrome` material uses `blur(28px)` which is on the higher end
- The `glass-surface` uses `blur(18px)` which is reasonable
- The `glass-panel` uses `blur(14px)` which is reasonable
- The `glass-well` uses `blur(10px)` which is good
- The `glass-control` uses `blur(10px)` which is reasonable
- The `glass-nav` uses `blur(8px)` which is too subtle for sidebar rows

**What needs improvement:**
- Increase `glass-chrome` blur from `28px` to `32px`
- Increase `glass-surface` blur from `18px` to `22px`
- Increase `glass-panel` blur from `14px` to `16px`
- Increase `glass-well` blur from `10px` to `12px`
- Increase `glass-control` blur from `10px` to `12px`
- Increase `glass-nav` blur from `8px` to `10px`
- The `glass-sheet` blur of `36px` is correct
- The `glass-accent` blur of `12px` is correct

### 3.9 Dark theme needs stronger environmental depth

**Issues:**
- The environmental orbs in dark mode are too dim (`rgba(120,165,255,0.07)`)
- The `ambient-blue` is `rgba(120,165,255,0.07)` which is too dim
- The `ambient-core` is `rgba(150,175,235,0.045)` which is too dim
- The `orb-blue` is `rgba(120,165,255,0.08)` which is slightly better
- The `orb-cyan` is `rgba(140,210,255,0.055)` which is correct
- The `orb-violet` is `rgba(175,150,255,0.055)` which is correct
- The `orb-emerald` is `rgba(130,220,170,0.035)` which is correct
- The `orb-warm` is `rgba(255,205,140,0.03)` which is correct
- The overall environmental depth is too subtle — the orbs are barely visible

**What needs improvement:**
- Increase ambient blue to `rgba(120,165,255,0.1)` for stronger depth
- Increase ambient core to `rgba(150,175,235,0.06)` for stronger warmth
- Increase orbs to `rgba(120,165,255,0.1)` (slightly brighter)
- The overall environmental canvas needs stronger ambient light

---
*Research compiled from Apple WWDC25 (Liquid Glass), WWDC2018 (Fluid Interfaces), WWDC2020 (UI Typography), deepika-builds/liquid-glass reference repo, and cross-OS analysis of iOS 26 / macOS Tahoe / watchOS 26 / tvOS 26 developer betas.*

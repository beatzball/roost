import { css } from 'lit';

/**
 * Typography that every shadow root needs, in one place.
 *
 * ## Why this file exists
 *
 * A shadow root does not hide the font. Three things reach into one perfectly
 * well, and all three were verified in a browser against this site:
 *
 *   - `@font-face`, which is document-scoped. Declare it once in
 *     public/styles/starlight.css and the face is usable everywhere. It does
 *     NOT need repeating here or anywhere else.
 *   - Inherited properties. `font-family` is inherited, so an element in a
 *     shadow root with no rule of its own takes the value from its host, and
 *     so on up to `html`.
 *   - Custom properties. `--sl-font-mono` crosses every boundary, which is why
 *     the rules below can name it.
 *
 * What does NOT reach in is a **selector**. `h1 { font-family: ... }` in the
 * global stylesheet matches no element inside any shadow root, ever. That is
 * the whole of the problem this file solves, and it is shadow DOM behaving as
 * specified — not Litro, and not Lit.
 *
 * ## How to use it
 *
 * Every component with a shadow root puts this first in its styles:
 *
 * ```ts
 * import { typography } from '../styles/typography.js';
 *
 * static override styles = [typography, css`  ...own rules...  `];
 * ```
 *
 * First, so the component's own rules still win on anything they set. Lit
 * shares one constructable stylesheet across every root that adopts it, so
 * adding it to a component that has no heading today costs nothing and means
 * the one it grows tomorrow is already right.
 *
 * ## What belongs here
 *
 * Rules on plain HTML elements that should look the same in every component.
 * Not layout, not colour, not anything one component decides. If you find
 * yourself adding a component's own class name below, it belongs in that
 * component instead — with the one exception of `.mono`, which is the handle
 * for an element that is not a heading and not code but should still be set
 * in the mono face (a label, a wordmark).
 */
export const typography = css`
  h1,
  h2,
  h3,
  h4,
  h5,
  h6 {
    font-family: var(--sl-font-mono, ui-monospace, monospace);
  }

  code,
  kbd,
  samp,
  pre {
    font-family: var(--sl-font-mono, ui-monospace, monospace);
  }

  /* For an element that is neither: a nav label, a wordmark, a small-caps
     group heading that is marked up as a <p> because it is not a document
     heading. Add the class in the template rather than a new rule here. */
  .mono {
    font-family: var(--sl-font-mono, ui-monospace, monospace);
  }
`;

export default typography;

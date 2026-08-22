import { LitElement, html, css } from 'lit';
import { customElement, property } from 'lit/decorators.js';

/**
 * Site footer crediting the framework the site was scaffolded with.
 *
 * <litro-footer recipe="starlight"></litro-footer>
 *
 * Deliberately quiet: a credit line should sit at the bottom of the page and
 * be findable, not compete with the content above it. Delete the element from
 * the page templates if you would rather not carry it.
 */
@customElement('litro-footer')
export class LitroFooter extends LitElement {
  static override properties = {
    recipe: { type: String },
  };

  static override styles = css`
    :host {
      display: block;
    }

    footer {
      border-top: 1px solid var(--sl-color-border, #e8e8e8);
      padding: 1.5rem;
      text-align: center;
      font-size: var(--sl-text-sm, 0.875rem);
      color: var(--sl-color-gray-4, #757575);
    }

    a {
      color: inherit;
      text-decoration: underline;
      text-underline-offset: 2px;
    }

    a:hover {
      color: var(--sl-color-accent, #7c3aed);
    }

    .recipe {
      /* The separator is decorative; a screen reader gets the comma in the
         visually-hidden text instead. */
      white-space: nowrap;
    }
  `;

  /** Recipe the site was scaffolded from, e.g. "starlight". */
  recipe = '';

  override render() {
    return html`
      <footer>
        Created using
        <a href="https://litro.dev" target="_blank" rel="noopener">Litro</a>${this
          .recipe
          ? html`<span class="recipe">, ${this.recipe} recipe</span>`
          : ''}
      </footer>
    `;
  }
}

export default LitroFooter;

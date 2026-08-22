import { LitElement, html, css } from "lit";
import { customElement } from "lit/decorators.js";

export interface NavItem {
  label: string;
  href: string;
}

/**
 * <starlight-header siteTitle="My Docs" .nav=${nav} currentPath="/docs/getting-started">
 *   Top navigation bar with site title, nav links, and dark/light theme toggle.
 */
@customElement("starlight-header")
export class StarlightHeader extends LitElement {
  static override properties = {
    siteTitle: { type: String },
    nav: { type: Array },
    currentPath: { type: String },
    navOpen: { type: Boolean },
    hasSidebar: { type: Boolean },
    _theme: { type: String, state: true },
  };

  static override styles = css`
    :host {
      display: block;
      position: sticky;
      top: 0;
      z-index: 100;
    }

    header {
      height: var(--sl-nav-height, 3.5rem);
      background-color: var(--sl-color-bg-nav, #fff);
      border-bottom: 1px solid var(--sl-color-border, #e8e8e8);
      display: flex;
      align-items: center;
      padding: 0 var(--sl-content-pad-x, 1.5rem);
      gap: 1rem;
    }

    .menu-btn {
      display: none;
      appearance: none;
      background: none;
      border: 1px solid var(--sl-color-border, #e8e8e8);
      border-radius: var(--sl-border-radius, 0.375rem);
      width: 2.25rem;
      height: 2.25rem;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      color: var(--sl-color-text, #23262f);
      transition: background-color 0.15s;
      flex-shrink: 0;
      padding: 0;
    }

    .menu-btn:hover {
      background-color: var(--sl-color-gray-2, #e8e8e8);
    }

    .menu-btn svg {
      width: 1.1rem;
      height: 1.1rem;
    }

    @media (max-width: 72rem) {
      .menu-btn {
        display: flex;
      }
    }

    .site-title {
      font-size: var(--sl-text-lg, 1.125rem);
      font-weight: 700;
      color: var(--sl-color-text, #23262f);
      text-decoration: none;
      white-space: nowrap;
      display: inline-flex;
      align-items: center;
      gap: 0.5rem;
    }

    .site-logo {
      /* Fixed box so the header never reflows while the image loads. */
      width: 1.75rem;
      height: 1.75rem;
      object-fit: contain;
      flex-shrink: 0;
    }

    /* Actions sit together on the right; the toggle used to claim the space
       on its own with margin-left:auto, which left no room for GitHub. */
    .header-actions {
      margin-left: auto;
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-shrink: 0;
    }

    .github-link {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 2.25rem;
      height: 2.25rem;
      border: 1px solid var(--sl-color-border, #e8e8e8);
      border-radius: var(--sl-border-radius, 0.375rem);
      color: var(--sl-color-text, #23262f);
      text-decoration: none;
      transition: background-color 0.15s;
    }

    .github-link:hover {
      background: var(--sl-color-bg-nav, #f6f6f6);
    }

    .github-link svg {
      width: 1.125rem;
      height: 1.125rem;
      fill: currentColor;
    }

    .site-title:hover {
      opacity: 0.85;
    }

    nav {
      display: flex;
      align-items: center;
      gap: 0.25rem;
      flex: 1;
    }

    nav a {
      padding: 0.35rem 0.75rem;
      font-size: var(--sl-text-sm, 0.875rem);
      font-weight: 500;
      color: var(--sl-color-gray-5, #4b4b4b);
      text-decoration: none;
      border-radius: var(--sl-border-radius, 0.375rem);
      transition:
        color 0.15s,
        background-color 0.15s;
    }

    nav a:hover {
      color: var(--sl-color-text, #23262f);
      background-color: var(--sl-color-gray-2, #e8e8e8);
    }

    nav a[aria-current="page"] {
      color: var(--sl-color-accent, #7c3aed);
      background-color: var(--sl-color-accent-low, #ede9fe);
    }

    .theme-toggle {
      appearance: none;
      background: none;
      border: 1px solid var(--sl-color-border, #e8e8e8);
      border-radius: var(--sl-border-radius, 0.375rem);
      width: 2.25rem;
      height: 2.25rem;
      display: flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      font-size: 1rem;
      color: var(--sl-color-text, #23262f);
      transition: background-color 0.15s;
      flex-shrink: 0;
    }

    .theme-toggle svg {
      width: 1.125rem;
      height: 1.125rem;
    }

    .theme-toggle:hover {
      background-color: var(--sl-color-gray-2, #e8e8e8);
    }
  `;

  siteTitle = "";
  nav: NavItem[] = [];
  currentPath = "";
  navOpen = false;
  hasSidebar = false;

  _theme = "dark";

  override firstUpdated() {
    // Read what the head script already decided rather than re-deriving it.
    // If the two ever disagree the toggle shows the wrong icon, and clicking
    // it appears to do nothing for one press.
    const attr =
      typeof document !== "undefined"
        ? document.documentElement.getAttribute("data-theme")
        : null;
    let stored: string | null = null;
    try {
      stored = typeof localStorage !== "undefined"
        ? localStorage.getItem("sl-theme")
        : null;
    } catch {
      // Private browsing can throw on access; fall through to the default.
    }
    const resolved =
      attr === "light" || attr === "dark"
        ? attr
        : stored === "light" || stored === "dark"
          ? stored
          : "dark";
    this._theme = resolved;
    if (typeof document !== "undefined") {
      document.documentElement.setAttribute("data-theme", resolved);
    }
  }

  private _toggleTheme() {
    const next = this._theme === "light" ? "dark" : "light";
    this._theme = next;
    if (typeof localStorage !== "undefined") {
      localStorage.setItem("sl-theme", next);
    }
    if (typeof document !== "undefined") {
      document.documentElement.setAttribute("data-theme", next);
    }
  }

  private _toggleNav() {
    this.dispatchEvent(
      new CustomEvent("sl-nav-toggle", { bubbles: true, composed: true }),
    );
  }

  override render() {
    // GitHub gets its own icon button rather than sitting in the text nav,
    // matching litro.dev. Matched on href so a relabelled entry still works.
    const isGithub = (item: { label: string; href: string }) =>
      /github\.com/i.test(item.href);
    const githubItem = this.nav.find(isGithub);
    const regularNav = this.nav.filter((item) => !isGithub(item));

    // Inline SVG rather than an emoji: emoji render at wildly different sizes
    // and weights per platform, so the button jumped around next to the
    // GitHub mark.
    const icon =
      this._theme === "dark"
        ? html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
              stroke-width="2" stroke-linecap="round" aria-hidden="true">
              <circle cx="12" cy="12" r="4" />
              <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
            </svg>`
        : html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
              stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
              aria-hidden="true">
              <path d="M21 12.8A9 9 0 1111.2 3a7 7 0 009.8 9.8z" />
            </svg>`;
    const label =
      this._theme === "dark" ? "Switch to light mode" : "Switch to dark mode";

    return html`
      <header>
        ${this.hasSidebar
          ? html`
              <button
                class="menu-btn"
                aria-label="${this.navOpen
                  ? "Close navigation"
                  : "Open navigation"}"
                aria-expanded="${this.navOpen}"
                @click="${this._toggleNav}"
              >
                ${this.navOpen
                  ? html`
                      <svg
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        stroke-linecap="round"
                        aria-hidden="true"
                      >
                        <line x1="18" y1="6" x2="6" y2="18" />
                        <line x1="6" y1="6" x2="18" y2="18" />
                      </svg>
                    `
                  : html`
                      <svg
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        stroke-linecap="round"
                        aria-hidden="true"
                      >
                        <line x1="3" y1="6" x2="21" y2="6" />
                        <line x1="3" y1="12" x2="21" y2="12" />
                        <line x1="3" y1="18" x2="21" y2="18" />
                      </svg>
                    `}
              </button>
            `
          : ""}
        <a class="site-title" href="/">
          <img class="site-logo" src="/logo.png" alt="" aria-hidden="true" />
          ${this.siteTitle}
        </a>
        <nav aria-label="Main navigation">
          ${regularNav.map(
            (item) => html`
              <a
                href="${item.href}"
                aria-current="${this.currentPath.startsWith(item.href)
                  ? "page"
                  : "false"}"
                >${item.label}</a
              >
            `,
          )}
        </nav>
        <div class="header-actions">
          ${githubItem
            ? html`
                <a
                  class="github-link"
                  href="${githubItem.href}"
                  target="_blank"
                  rel="noopener"
                  aria-label="GitHub (opens in new tab)"
                >
                  <svg viewBox="0 0 24 24" aria-hidden="true">
                    <path
                      d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z"
                    />
                  </svg>
                </a>
              `
            : ""}
          <button
            class="theme-toggle"
            aria-label="${label}"
            @click="${this._toggleTheme}"
          >
            ${icon}
          </button>
        </div>
      </header>
    `;
  }
}

export default StarlightHeader;

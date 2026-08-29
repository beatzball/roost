import { html } from 'lit';
import { customElement } from 'lit/decorators.js';
import { LitroPage } from '@beatzball/litro/runtime';
import { definePageData } from '@beatzball/litro';
import { getGlobalData } from 'litro:content';
import { siteConfig } from '../server/starlight.config.js';
import { starlightHead } from '../src/route-meta.js';
import { buildSeoHead, buildSeoTitle } from '../src/seo.js';

// Register components used in render()
import '../src/components/starlight-header.js';
import '../src/components/litro-card.js';
import '../src/components/litro-card-grid.js';
import '../src/components/litro-footer.js';

/**
 * The four commands that take someone from nothing to a running agent view.
 * Kept in step with the Install and First run sections of
 * content/docs/getting-started.md.
 */
const INSTALL_STEPS = [
  {
    note: 'install (clones roost and puts it on your PATH)',
    cmd: 'curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh',
  },
  { note: 'check tmux version, truecolor, fzf, hooks, adapter links, notifier', cmd: 'roost doctor' },
  { note: 'pick a theme and print the agent hooks', cmd: 'roost init' },
  { note: 'start (or attach to) the default session', cmd: 'roost' },
] as const;

/** The bindings that pay for themselves on the first day. */
const KEY_HINTS = [
  { keys: 'Ctrl-s a', what: 'Agent switcher — every agent, its state, and how long it has been there' },
  { keys: 'Ctrl-s b', what: 'Jump straight to the agent that needs you (error first, then blocked)' },
  { keys: 'Ctrl-s S', what: 'Settings — change theme, glyphs, separator and notifications, live' },
] as const;

/**
 * Which harnesses drive the badges today, and how.
 *
 * Claude Code, opencode, GitHub Copilot CLI and pi have code in this repo;
 * everything else reports through `roost state`, which any harness can call.
 * Kept in step with content/docs/state-badges.md.
 */
const AGENTS = [
  {
    name: 'Claude Code',
    how: 'Four lifecycle hooks. Print them with',
    cmd: 'roost hooks',
  },
  {
    name: 'opencode',
    how: 'A plugin adapter ships in the repo. Link it with',
    cmd: 'roost doctor',
  },
  {
    name: 'GitHub Copilot CLI',
    how: 'An extension adapter ships in the repo. Link it with',
    cmd: 'roost doctor',
  },
  {
    name: 'pi',
    how: 'An extension adapter ships in the repo. Link it with',
    cmd: 'roost doctor',
  },
  {
    name: 'Anything else',
    how: 'One command, from any harness, in any language.',
    cmd: 'roost state working',
  },
] as const;

/** Harnesses with an adapter planned, but not written yet. */
const AGENTS_PLANNED = ['Codex'] as const;

export interface SplashData {
  siteTitle: string;
  description: string;
  nav: Array<{ label: string; href: string }>;
  features: Array<{ title: string; description: string; icon?: string }>;
  /**
   * Raw <head> HTML. Litro injects this and strips it from the JSON payload
   * before serializing — it contains no </script>, but the framework treats
   * the key specially regardless. See src/seo.ts.
   */
  seoHead: string;
  /** Overrides routeMeta.title, which cannot vary per request. */
  seoTitle: string;
}

export const pageData = definePageData(async (_event) => {
  const metadata = await getGlobalData();
  const siteTitle = String(metadata.title ?? siteConfig.title);
  const description = String(metadata.description ?? siteConfig.description);

  return {
    siteTitle,
    description,
    seoTitle: buildSeoTitle(siteTitle),
    seoHead: buildSeoHead({ title: siteTitle, description, path: '/' }),
    nav: siteConfig.nav,
    features: [
      {
        icon: '🪺',
        title: 'Isolated tmux',
        description: 'Runs on its own tmux server with its own config. Your everyday tmux is never touched.',
      },
      {
        icon: '🚦',
        title: 'Honest badges',
        description: 'State is reported by the agent itself — hooks, not screen-scraping. Accurate, not guessed.',
      },
      {
        icon: '🎛️',
        title: 'Drive the fleet',
        description: 'send, read and wait-done turn tmux scripting into agent-shaped commands you can loop over.',
      },
      {
        icon: '📜',
        title: 'Just shell',
        description: 'A launcher, a tmux config and a few small scripts. No daemon, no binary, no plugin manager.',
      },
    ],
  } satisfies SplashData;
});

export const routeMeta = {
  head: starlightHead,
  title: 'roost',
};

@customElement('page-home')
export class SplashPage extends LitroPage {
  override render() {
    const data = this.serverData as SplashData | null;
    const { siteTitle = 'roost', description = '', nav = [], features = [] } = data ?? {};

    return html`
      <div style="min-height:100vh;display:flex;flex-direction:column;">
        <starlight-header
          siteTitle="${siteTitle}"
          .nav="${nav}"
          currentPath="/"
        ></starlight-header>
        <main style="
          flex:1;
          max-width:56rem;
          margin:0 auto;
          padding:4rem 1.5rem 3rem;
          width:100%;
        ">
          <section style="text-align:center;margin-bottom:4rem;">
            <img
              src="/logo.png"
              alt=""
              width="160"
              height="162"
              style="
                display:block;
                margin:0 auto 1.5rem;
                width:clamp(96px,18vw,160px);
                height:auto;
              "
            />
            <h1 style="
              font-size:clamp(2rem,5vw,3.5rem);
              font-weight:800;
              color:var(--sl-color-text);
              margin:0 0 1rem;
              line-height:1.1;
            ">${siteTitle}</h1>
            ${description ? html`
              <p style="
                font-size:var(--sl-text-xl);
                color:var(--sl-color-gray-4);
                max-width:36rem;
                margin:0 auto 2.5rem;
                line-height:1.6;
              ">${description}</p>
            ` : ''}
            <div style="display:flex;gap:1rem;justify-content:center;flex-wrap:wrap;">
              <a href="/docs/getting-started" style="
                display:inline-block;
                padding:0.6rem 1.5rem;
                background:var(--sl-color-accent);
                color:var(--sl-color-text-invert,#fff);
                border-radius:var(--sl-border-radius);
                font-weight:600;
                text-decoration:none;
                font-size:var(--sl-text-base);
              ">Get Started</a>
              <a href="https://github.com/beatzball/roost" style="
                display:inline-block;
                padding:0.6rem 1.5rem;
                border:1px solid var(--sl-color-border);
                color:var(--sl-color-text);
                border-radius:var(--sl-border-radius);
                font-weight:600;
                text-decoration:none;
                font-size:var(--sl-text-base);
              ">GitHub</a>
            </div>
          </section>

          <!-- Install and first run: the four commands, in order, so the
               landing page answers "how do I start" without a click. -->
          <section style="margin-bottom:4rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 1rem;
              text-align:center;
            ">Get running</h2>
            <div style="
              background:var(--sl-color-bg-inline-code,#f6f6f6);
              border:1px solid var(--sl-color-border);
              border-radius:var(--sl-border-radius);
              padding:1.25rem 1.5rem;
              overflow-x:auto;
              max-width:44rem;
              margin:0 auto;
            ">
              <pre style="margin:0;font-size:var(--sl-text-sm);line-height:1.9;"><code>${INSTALL_STEPS.map(
                (step) => html`<span style="color:var(--sl-color-gray-4);"># ${step.note}</span>
<span style="color:var(--sl-color-text);">${step.cmd}</span>
`,
              )}</code></pre>
            </div>
          </section>

          <!-- The three bindings worth knowing on day one. The full table
               lives in the docs; this is the short answer. -->
          <section style="margin-bottom:4rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 0.5rem;
              text-align:center;
            ">Keys worth knowing</h2>
            <p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              margin:0 0 1.5rem;
            ">The prefix is <code>Ctrl-s</code>.</p>
            <div style="
              display:grid;
              gap:0.75rem;
              max-width:44rem;
              margin:0 auto;
            ">
              ${KEY_HINTS.map(
                (k) => html`
                  <div style="
                    display:flex;
                    align-items:baseline;
                    gap:1rem;
                    padding:0.75rem 1rem;
                    border:1px solid var(--sl-color-border);
                    border-radius:var(--sl-border-radius);
                  ">
                    <kbd style="
                      flex-shrink:0;
                      font-family:var(--sl-font-mono,ui-monospace,monospace);
                      font-size:var(--sl-text-sm);
                      background:var(--sl-color-bg-inline-code,#f6f6f6);
                      border:1px solid var(--sl-color-border);
                      border-radius:0.25rem;
                      padding:0.15rem 0.5rem;
                      white-space:nowrap;
                    ">${k.keys}</kbd>
                    <span style="color:var(--sl-color-text);font-size:var(--sl-text-base);">
                      ${k.what}
                    </span>
                  </div>
                `,
              )}
            </div>
          </section>

          <!-- Which harnesses this works with. The badges are the whole
               point of roost, so "does it work with my agent" has to be
               answerable without opening the docs. -->
          <section style="margin-bottom:4rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 0.5rem;
              text-align:center;
            ">Works with your agent</h2>
            <p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              margin:0 0 1.5rem;
            ">Badges come from the agent, so any harness can drive them.</p>
            <div style="
              display:grid;
              /* 13rem, not 15rem: at the 44rem cap that is the difference
                 between three cards on one row and two plus an orphan. */
              grid-template-columns:repeat(auto-fit,minmax(13rem,1fr));
              gap:0.75rem;
              max-width:44rem;
              margin:0 auto;
            ">
              ${AGENTS.map(
                (a) => html`
                  <div style="
                    padding:1rem;
                    border:1px solid var(--sl-color-border);
                    border-radius:var(--sl-border-radius);
                    display:flex;
                    flex-direction:column;
                    gap:0.5rem;
                  ">
                    <span style="
                      font-weight:700;
                      color:var(--sl-color-text);
                      font-size:var(--sl-text-base);
                    ">${a.name}</span>
                    <span style="
                      color:var(--sl-color-gray-4);
                      font-size:var(--sl-text-sm);
                      line-height:1.5;
                    ">${a.how}</span>
                    <code style="
                      font-family:var(--sl-font-mono,ui-monospace,monospace);
                      font-size:var(--sl-text-sm);
                      background:var(--sl-color-bg-inline-code,#f6f6f6);
                      border:1px solid var(--sl-color-border);
                      border-radius:0.25rem;
                      padding:0.25rem 0.5rem;
                      align-self:flex-start;
                    ">${a.cmd}</code>
                  </div>
                `,
              )}
            </div>
            <p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              margin:1.25rem 0 0;
            ">
              Dedicated adapters planned for ${AGENTS_PLANNED.join(', ')}.
            </p>
          </section>

          <section>
            <litro-card-grid>
              ${features.map(f => html`
                <litro-card
                  icon="${f.icon ?? ''}"
                  title="${f.title}"
                  description="${f.description}"
                ></litro-card>
              `)}
            </litro-card-grid>
          </section>
        </main>
        <litro-footer recipe="starlight"></litro-footer>
      </div>
    `;
  }
}

export default SplashPage;

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

/**
 * The three complaints roost was written to answer, and the answer to each.
 *
 * Every `fix` here has to be something roost already does -- the commands are
 * the proof, and a reader will run them. Kept in step with
 * content/docs/how-it-works.md and content/docs/driving-a-fleet.md.
 */
const PAINS = [
  {
    pain: 'Your own tmux fills up with agents.',
    fix: 'roost runs on a tmux server of its own, with its own config and its own prefix. Your everyday sessions never see it, and one command puts the whole thing away.',
    cmd: 'roost   ·   roost kill',
  },
  {
    pain: 'You cannot tell which agent is waiting on you.',
    fix: 'Each agent reports its own state through a hook or an adapter, so a badge is what the agent said, not what its screen happened to look like. One key takes you to the one that needs you — error first, then blocked.',
    cmd: 'Ctrl-s b',
  },
  {
    pain: 'Driving agents from a script means scraping their screens.',
    fix: 'read returns the reply the agent recorded as its turn ended, not the input box and status bars drawn underneath it. wait-done blocks until a pane is finished and exits 2 if the agent died, so a script can branch instead of guessing.',
    cmd: 'roost send   ·   roost read   ·   roost wait-done',
  },
] as const;

/**
 * Three shapes of fleet, smallest first. A reader who only wants the first one
 * should not have to read about the third to find out roost suits them.
 * Kept in step with content/docs/driving-a-fleet.md.
 */
const FLEET_SHAPES = [
  {
    title: 'By hand',
    what: 'One agent per job, and a switcher that lists every one of them with its state and how long it has been there.',
    cmd: 'roost new api',
  },
  {
    title: 'From a shell script',
    what: 'Prompt each agent, then wait for all of them. A loop over two commands is the whole orchestrator.',
    cmd: 'for w in api web worker; do roost send "$w" "run the tests"; done',
  },
  {
    title: 'Agent-driven',
    what: 'One agent opens the others, prompts them, reads their replies, and hands the result to a human in a pane that never steals focus.',
    cmd: 'roost spawn   ·   roost send   ·   roost read   ·   roost view',
  },
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
 * Claude Code, opencode, GitHub Copilot CLI, pi and Codex have code in this
 * repo; everything else reports through `roost state`, which any harness can
 * call. Kept in step with content/docs/state-badges.md.
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
    name: 'Codex',
    how: 'Four hooks, plus one trust prompt. Print them with',
    cmd: 'roost hooks codex',
  },
  {
    name: 'Anything else',
    // Not an adapter: it is the fallback every harness has without one. Flagged
    // rather than counted out by position, because the paragraph below reports
    // how many adapters ship and a sixth card would otherwise make that number
    // wrong silently.
    generic: true,
    how: 'One command, from any harness, in any language.',
    cmd: 'roost state working',
  },
] as const;

/** How many of the cards above are real adapters in this repo. */
const ADAPTER_COUNT = AGENTS.filter((a) => !('generic' in a)).length;

/** Harnesses with an adapter planned, but not written yet. */
const AGENTS_PLANNED = [] as const;

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
    // Six, not four: the card grid settles at three columns at this page
    // width, so four cards render as a row of three plus a lone orphan. Keep
    // the length a multiple of three.
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
      {
        icon: '🔌',
        title: 'Wires itself in',
        description: 'An agent started in a roost pane picks up the hook files roost owns. Your real config is left alone.',
      },
      {
        icon: '🛰️',
        title: 'Agents on other hosts',
        description: 'roost ssh runs roost on a remote machine. The agents live there; you drive them from here.',
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

          <!-- What it looks like, before what to type. A visitor decides
               whether this is their kind of tool from this image, so it comes
               before the install block rather than after it.
               
               Recorded, not screenshotted: demo/roost-hero.tape drives a real
               fleet built by demo/seed-fleet.sh, on a throwaway roost server
               with a seeded /tmp repo, so re-recording it is one command and
               nothing of the author's machine is in the frame. Sized 1800x620
               (the real file) so the space is reserved and nothing below it
               jumps once the image arrives. -->
          <!-- Wider than the 56rem prose column it sits in. The source is
               1800px of terminal; held to the text width it renders at half
               scale and the state names in the switcher stop being legible.
               92vw rather than a fixed width so a phone still gets a gutter
               and the page never scrolls sideways. -->
          <section style="
            margin-bottom:3rem;
            width:min(92vw,68rem);
            margin-left:50%;
            transform:translateX(-50%);
          ">
            <img
              src="/roost-hero.png"
              alt="A roost session with five agent windows across the top, each badged with its state. An agent has answered in the pane behind, and the agent switcher lists all five with their states and how long each has been there."
              width="1800"
              height="620"
              decoding="async"
              style="
                display:block;
                width:100%;
                height:auto;
                border:1px solid var(--sl-color-border);
                border-radius:var(--sl-border-radius);
              "
            />
            <p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              line-height:1.6;
              max-width:36rem;
              margin:0.75rem auto 0;
            ">
              One roost session, five agents. The top line is the fleet, and the
              switcher lists every agent with its state and how long it has been
              there — reported by the agents, not scraped off their screens.
            </p>
          </section>

          <!-- The four reasons to care. These used to sit at the very bottom,
               under three how-to sections, where a first-time visitor never
               reached them. Why before how. -->
          <section style="margin-bottom:4rem;">
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

          <!-- The complaint, then the answer. The cards above say what roost
               is; this says what it is FOR. A reader who does not recognise
               one of these three problems is not the audience, and finding
               that out here costs them ten seconds instead of an install. -->
          <section style="margin-bottom:4rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 1.5rem;
              text-align:center;
            ">What it fixes</h2>
            <div style="display:grid;gap:1rem;max-width:44rem;margin:0 auto;">
              ${PAINS.map(
                (p) => html`
                  <div style="
                    padding:1.25rem 1.5rem;
                    border:1px solid var(--sl-color-border);
                    border-radius:var(--sl-border-radius);
                  ">
                    <p style="
                      margin:0 0 0.5rem;
                      font-weight:700;
                      color:var(--sl-color-text);
                      font-size:var(--sl-text-base);
                    ">${p.pain}</p>
                    <p style="
                      margin:0 0 0.75rem;
                      color:var(--sl-color-gray-4);
                      font-size:var(--sl-text-sm);
                      line-height:1.6;
                    ">${p.fix}</p>
                    <code style="
                      display:inline-block;
                      font-family:var(--sl-font-mono,ui-monospace,monospace);
                      font-size:var(--sl-text-sm);
                      background:var(--sl-color-bg-inline-code,#f6f6f6);
                      border:1px solid var(--sl-color-border);
                      border-radius:0.25rem;
                      padding:0.25rem 0.5rem;
                    ">${p.cmd}</code>
                  </div>
                `,
              )}
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

          <!-- Named shapes of work. The commands are on the page already;
               what was missing was the sentence that says which of them a
               given reader actually needs. Smallest first. -->
          <section style="margin-bottom:4rem;">
            <h2 style="
              font-size:var(--sl-text-xl);
              font-weight:700;
              color:var(--sl-color-text);
              margin:0 0 0.5rem;
              text-align:center;
            ">Three ways to run a fleet</h2>
            <p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              margin:0 0 1.5rem;
            ">Pick one. They use the same commands.</p>
            <div style="display:grid;gap:0.75rem;max-width:44rem;margin:0 auto;">
              ${FLEET_SHAPES.map(
                (shape, i) => html`
                  <div style="
                    padding:1.25rem 1.5rem;
                    border:1px solid var(--sl-color-border);
                    border-radius:var(--sl-border-radius);
                  ">
                    <p style="
                      margin:0 0 0.5rem;
                      font-weight:700;
                      color:var(--sl-color-text);
                      font-size:var(--sl-text-base);
                    ">
                      <span style="color:var(--sl-color-gray-4);">${i + 1}.</span>
                      ${shape.title}
                    </p>
                    <p style="
                      margin:0 0 0.75rem;
                      color:var(--sl-color-gray-4);
                      font-size:var(--sl-text-sm);
                      line-height:1.6;
                    ">${shape.what}</p>
                    <code style="
                      display:block;
                      font-family:var(--sl-font-mono,ui-monospace,monospace);
                      font-size:var(--sl-text-sm);
                      background:var(--sl-color-bg-inline-code,#f6f6f6);
                      border:1px solid var(--sl-color-border);
                      border-radius:0.25rem;
                      padding:0.35rem 0.5rem;
                      overflow-x:auto;
                      white-space:pre;
                    ">${shape.cmd}</code>
                  </div>
                `,
              )}
            </div>
            <p style="
              text-align:center;
              font-size:var(--sl-text-sm);
              margin:1.5rem 0 0;
            ">
              <a href="/docs/driving-a-fleet" style="
                color:var(--sl-color-text-accent,var(--sl-color-accent));
                text-decoration:none;
                font-weight:600;
              ">All of it, with the exit codes →</a>
            </p>
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
            <!-- What this section closes on, now that AGENTS_PLANNED is
                 empty. "More are coming" was the honest message while it had
                 names in it; the honest message now is what a reader can rely
                 on, which is not the same as "everything works everywhere".
                 The two examples are the two real limits and both are stated
                 the same way on /docs/state-badges — if that page and this
                 sentence ever disagree, this one is wrong. -->
            <p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              line-height:1.6;
              max-width:34rem;
              margin:1.5rem auto 0;
            ">
              ${ADAPTER_COUNT} adapters ship in the repo, and every one of them
              badges its pane and reports its reply on its own — you wire it once.
              What each can signal is not identical: Codex has no error signal to
              pass on, and pi never asks permission, so a pi pane never blocks.
              <a href="/docs/state-badges" style="
                color:var(--sl-color-text-accent,var(--sl-color-accent));
                text-decoration:none;
                font-weight:600;
              ">Every harness's exact badge table →</a>
            </p>
            ${
              // Every harness that was ever on this list now ships, so the list
              // is empty and the sentence would read "planned for ." Rendered
              // conditionally rather than deleted: the array stays as the one
              // place to name the next one, and the paragraph comes back with it
              // -- underneath the paragraph above, which reads as the standing
              // statement with this one as the update to it.
              AGENTS_PLANNED.length
                ? `<p style="
              text-align:center;
              color:var(--sl-color-gray-4);
              font-size:var(--sl-text-sm);
              margin:0.75rem 0 0;
            ">
              Dedicated adapters planned for ${AGENTS_PLANNED.join(', ')}.
            </p>`
                : ''
            }
          </section>

        </main>
        <litro-footer recipe="starlight"></litro-footer>
      </div>
    `;
  }
}

export default SplashPage;

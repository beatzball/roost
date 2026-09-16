import { html, css, type TemplateResult } from 'lit';
import { customElement } from 'lit/decorators.js';
import { LitroPage } from '@beatzball/litro/runtime';
import { definePageData } from '@beatzball/litro';
import { getGlobalData } from 'litro:content';
import { siteConfig } from '../server/starlight.config.js';
import { starlightHead } from '../src/route-meta.js';
import { buildSeoHead, buildSeoTitle } from '../src/seo.js';
import { typography } from '../src/styles/typography.js';

/*
 * The landing page is drawn in roost's own vocabulary.
 *
 * Nothing on it is a stock marketing device standing in for the product: the
 * bar across the top is a roost status line, the badges are roost's `ascii`
 * glyph set (scripts/lib/roost-config.sh), the colours are the `roost` theme
 * (scripts/roost-themes.sh) and the owl's own gradient, and every command is
 * one a reader can paste. When roost changes how any of those look, this page
 * should change with it.
 *
 * The docs pages do not share any of this. They keep the calmer layout in
 * src/components/starlight-page.ts, because docs are read, not scanned.
 */

/** The install one-liner. Kept in step with content/docs/getting-started.md. */
const INSTALL_CMD = 'curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh';

/**
 * roost's `ascii` glyph set, in its canonical urgency order. Copied from
 * roost_glyphset in scripts/lib/roost-config.sh rather than invented: it is the
 * one set that renders in any font, and a visitor who installs roost and picks
 * it sees exactly these.
 */
const GLYPH = {
  error: '[x]',
  blocked: '[!]',
  working: '[~]',
  done: '[+]',
  idle: '[·]',
} as const;
type State = keyof typeof GLYPH;

/**
 * The fleet in the status line. Every tab boots as working, then settles on
 * `to` at `at` seconds -- the one piece of motion on the page, and the thing it
 * is about: a row of agents, each telling you what it is doing, one of them
 * needing you. `web` is still working when it settles, on purpose.
 */
const FLEET: ReadonlyArray<{ n: number; name: string; to: State; at: number; current?: true }> = [
  { n: 1, name: 'api', to: 'done', at: 1.6, current: true },
  { n: 2, name: 'web', to: 'working', at: 0 },
  { n: 3, name: 'worker', to: 'blocked', at: 1.0 },
  { n: 4, name: 'docs', to: 'idle', at: 2.6 },
  { n: 5, name: 'tests', to: 'error', at: 2.1 },
];

/**
 * What roost does, each with the command that does it and a small picture of
 * the result.
 *
 * `title` is the row's heading, and it states the RESULT, never the problem.
 * Headings get read on their own -- a visitor who skims past the section title
 * would otherwise read "Your own tmux fills up with agents." as something roost
 * causes. The problem belongs in `fix`, where the sentence around it makes the
 * direction clear.
 *
 * Every `fix` has to be something roost already does -- the commands are the
 * proof, and a reader will run them. Kept in step with content/docs/how-it-works.md
 * and content/docs/driving-a-fleet.md.
 */
const FIXES: ReadonlyArray<{ title: string; fix: string; cmds: readonly string[]; widget: () => TemplateResult }> = [
  {
    title: 'Go straight to the agent that is stuck.',
    fix: 'Each agent reports its own state through a hook or an adapter, so a badge is what the agent said, not what its screen happened to look like. One key takes you to the one that needs you: error first, then blocked.',
    cmds: ['Ctrl-s b'],
    widget: () => html`
      <div class="term" role="img" aria-label="Three agents listed by state. worker is blocked and highlighted; web is working; api is done.">
        <div class="row hot"><span class="s-blocked">${GLYPH.blocked} blocked</span><span>4m</span><span>worker</span></div>
        <div class="row"><span class="s-working">${GLYPH.working} working</span><span>5m</span><span>web</span></div>
        <div class="row"><span class="s-done">${GLYPH.done} done</span><span>1m</span><span>api</span></div>
      </div>
      <p class="widget-note"><kbd>Ctrl-s b</kbd> takes you to worker.</p>
    `,
  },
  {
    title: 'Your everyday tmux stays untouched.',
    fix: 'roost runs on a tmux server of its own, with its own config and its own prefix. Your everyday sessions never see it, and one command puts the whole thing away.',
    cmds: ['roost', 'roost kill'],
    widget: () => html`
      <div class="bars" role="img" aria-label="Two separate status lines. Your tmux shows zsh, vim and logs. roost's tmux shows three agents with badges.">
        <p class="bar-label">Your tmux</p>
        <div class="minibar"><span>0:zsh</span><span>1:vim</span><span>2:logs</span></div>
        <p class="bar-label">roost's tmux</p>
        <div class="minibar roosty">
          <span><b class="s-working">${GLYPH.working}</b> 1 api</span>
          <span><b class="s-blocked">${GLYPH.blocked}</b> 2 worker</span>
          <span><b class="s-done">${GLYPH.done}</b> 3 docs</span>
        </div>
      </div>
    `,
  },
  {
    title: 'Script your agents without scraping their screens.',
    fix: 'read returns the reply the agent recorded as its turn ended, not the input box drawn underneath it. wait-done blocks until a pane is finished and exits 2 if the agent died, so a script can branch instead of guessing.',
    cmds: ['roost send', 'roost wait-done', 'roost read'],
    widget: () => html`
      <pre class="term shell" aria-label="A shell session: wait-done returns 0, then read prints the agent's reply."><span class="p">$</span> roost wait-done api
<span class="p">$</span> echo $?
0
<span class="p">$</span> roost read api
- Roost gives each agent its own window in one
  shared tmux space.</pre>
    `,
  },
  {
    title: 'Run agents on a bigger machine, the same way.',
    fix: 'roost ssh starts roost on another host and attaches you to it. The agents run over there; the keys, the badges and every command stay the same.',
    cmds: ['roost ssh buildbox'],
    widget: () => html`
      <div class="bars" role="img" aria-label="A shell command, roost ssh buildbox, and the status line it opens, with two agents on the remote host.">
        <pre class="term shell"><span class="p">$</span> roost ssh buildbox</pre>
        <div class="minibar roosty">
          <span><b class="s-working">${GLYPH.working}</b> 1 train</span>
          <span><b class="s-done">${GLYPH.done}</b> 2 eval</span>
          <span class="host">buildbox</span>
        </div>
      </div>
    `,
  },
];

/**
 * The four commands that take someone from nothing to a running agent view.
 * A real sequence, so it is the one list on the page that is numbered. Kept in
 * step with the Install and First run sections of content/docs/getting-started.md.
 */
const INSTALL_STEPS = [
  { cmd: INSTALL_CMD, note: 'Clones roost and puts it on your PATH.' },
  { cmd: 'roost doctor', note: 'Checks tmux, truecolor, fzf, hooks and adapter links.' },
  { cmd: 'roost init', note: 'Picks a theme and prints the agent hooks.' },
  { cmd: 'roost', note: 'Starts the default session, or attaches to it.' },
] as const;

/** The bindings that pay for themselves on the first day. */
const KEY_HINTS = [
  { keys: 'Ctrl-s a', what: 'Every agent, its state, and how long it has been there.' },
  { keys: 'Ctrl-s b', what: 'Straight to the agent that needs you.' },
  { keys: 'Ctrl-s S', what: 'Theme, glyphs and notifications, changed live.' },
] as const;

/**
 * Three shapes of fleet, smallest first. A reader who only wants the first one
 * should not have to read about the third to find out roost suits them.
 * Kept in step with content/docs/driving-a-fleet.md.
 */
const FLEET_SHAPES = [
  {
    title: 'By hand',
    what: 'One agent per job, and a switcher that lists every one of them with its state.',
    cmd: 'roost new api',
  },
  {
    title: 'From a shell script',
    what: 'Prompt each agent, then wait for all of them. A loop over two commands is the whole orchestrator.',
    cmd: 'for w in api web; do roost send "$w" "run the tests"; done',
  },
  {
    title: 'Agent-driven',
    what: 'One agent opens the others, prompts them, reads their replies, and hands you the result without stealing focus.',
    cmd: 'roost spawn helper',
  },
] as const;

/**
 * Which harnesses drive the badges today, and how.
 *
 * Claude Code, opencode, GitHub Copilot CLI, pi and Codex have code in this
 * repo; everything else reports through `roost state`, which any harness can
 * call. Kept in step with content/docs/state-badges.md.
 */
const AGENTS = [
  { name: 'Claude Code', how: 'Lifecycle hooks', cmd: 'roost hooks' },
  { name: 'opencode', how: 'Plugin adapter', cmd: 'roost doctor' },
  { name: 'GitHub Copilot CLI', how: 'Extension adapter', cmd: 'roost doctor' },
  { name: 'pi', how: 'Extension adapter', cmd: 'roost doctor' },
  { name: 'Codex', how: 'Hooks, plus one trust prompt', cmd: 'roost hooks codex' },
  {
    name: 'Anything else',
    // Not an adapter: it is the fallback every harness has without one. Flagged
    // rather than counted out by position, because the paragraph below reports
    // how many adapters ship and an extra row would otherwise make that number
    // wrong silently.
    generic: true,
    how: 'One command, from any language',
    cmd: 'roost state working',
  },
] as const;

/** How many of the rows above are real adapters in this repo. */
const ADAPTER_COUNT = AGENTS.filter((a) => !('generic' in a)).length;

/** Harnesses with an adapter planned, but not written yet. */
const AGENTS_PLANNED = [] as const;

export interface SplashData {
  siteTitle: string;
  description: string;
  nav: Array<{ label: string; href: string }>;
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
  } satisfies SplashData;
});

export const routeMeta = {
  head: starlightHead,
  title: 'roost',
};

@customElement('page-home')
export class SplashPage extends LitroPage {
  static override properties = {
    copied: { state: true },
  };

  /** Which install box last copied, so only that one says so. */
  copied: '' | 'hero' | 'closing' | 'hero-selected' | 'closing-selected' = '';

  // typography first: headings, code and kbd take the mono face from it, and
  // `.mono` is the handle for everything else. See src/styles/typography.ts.
  static override styles = [
    typography,
    css`
      /* ── Tokens: the roost theme, the owl, and one colour per state ───── */
      :host {
        --night: #12101f; /* roost theme: status-line background */
        --pane: #211e38; /* roost theme: pane background */
        --line: #34304f; /* one step up from the pane, for hairlines */
        --ink: #e0dcf5;
        --text: #c8c3e0; /* roost theme: foreground */
        --dim: #8a84b0; /* roost theme: muted */
        --violet: #7c6ff0; /* roost theme: accent */
        --lilac: #bd93f9; /* roost theme: second accent */

        --s-error: #ff8a4c;
        --s-blocked: #ff5c7a;
        --s-working: #f1c96b;
        --s-done: #46dba7; /* the owl's crown */
        --s-idle: #8a84b0;

        --measure: 72rem;
        --gutter: clamp(1rem, 4vw, 2.5rem);

        display: block;
        min-height: 100vh;
        background: var(--night);
        color: var(--text);
        /* Dark always. The docs keep the light/dark toggle; this page is a
           terminal, and a terminal this page describes is dark. */
        color-scheme: dark;
      }

      * {
        box-sizing: border-box;
      }

      /* Monospace is wide, so headings wrap early, and without balancing the
         last word kept landing alone on its own line ("you.", "own."). */
      h1,
      h2,
      h3 {
        text-wrap: balance;
      }

      a {
        color: var(--lilac);
        text-decoration: underline;
        text-decoration-thickness: 1px;
        text-underline-offset: 0.2em;
      }
      a:hover {
        color: var(--ink);
      }
      a:focus-visible,
      button:focus-visible {
        outline: 2px solid var(--lilac);
        outline-offset: 3px;
        border-radius: 2px;
      }

      code,
      kbd {
        font-size: 0.875em;
        color: var(--ink);
        background: var(--pane);
        border: 1px solid var(--line);
        border-radius: 4px;
        padding: 0.1em 0.4em;
        white-space: nowrap;
      }

      .wrap {
        width: 100%;
        max-width: var(--measure);
        margin: 0 auto;
        padding: 0 var(--gutter);
      }

      .s-error { color: var(--s-error); }
      .s-blocked { color: var(--s-blocked); }
      .s-working { color: var(--s-working); }
      .s-done { color: var(--s-done); }
      .s-idle { color: var(--s-idle); }

      /* ── The status line: the page's one moving part ─────────────────── */
      .statusline {
        position: sticky;
        top: 0;
        z-index: 10;
        display: flex;
        align-items: stretch;
        gap: 0;
        height: 2.25rem;
        font-size: 0.875rem;
        background: color-mix(in srgb, var(--night) 88%, transparent);
        backdrop-filter: blur(8px);
        border-bottom: 1px solid var(--line);
      }

      /* Powerline segments: owl, then name, then the current tab.
         Every segment ends in the same arrow. Each one after the first slides
         --arrow to the left, UNDER the arrow before it (a lower z-index), so
         the notch the arrow cuts shows the next segment's colour rather than
         a square edge. The shape of roost's own status line. */
      .statusline {
        --arrow: 0.75rem;
      }
      .seg {
        position: relative;
        display: flex;
        align-items: center;
        clip-path: polygon(0 0, calc(100% - var(--arrow)) 0, 100% 50%, calc(100% - var(--arrow)) 100%, 0 100%);
      }

      /* One link, two segments: the owl and the name both go home. */
      .home {
        position: relative;
        z-index: 2;
        display: flex;
        align-items: stretch;
        text-decoration: none;
      }
      /* The segments paint over any outline on the link, so a ring showed
         only as a sliver in the arrow's notch. The name segment itself
         changes instead: lilac with dark underlined text is unmistakable and
         keeps the powerline shape. */
      .home:focus-visible {
        outline: none;
      }
      .home:focus-visible .seg-name {
        color: var(--night);
        background: var(--lilac);
        text-decoration: underline;
        text-decoration-thickness: 2px;
        text-underline-offset: 0.2em;
      }
      /* The owl on the dark, which is what it was drawn for. On the violet its
         blue and violet face disappeared into the block behind it. */
      .seg-owl {
        z-index: 2;
        padding: 0 calc(0.55rem + var(--arrow)) 0 var(--gutter);
        background: var(--night);
      }
      .seg-owl img {
        display: block;
        width: 1.375rem;
        height: 1.375rem;
      }
      .seg-name {
        z-index: 1;
        margin-left: calc(-1 * var(--arrow));
        padding: 0 calc(0.75rem + var(--arrow)) 0 calc(0.6rem + var(--arrow));
        color: #fff;
        font-weight: 700;
        background: var(--violet);
      }
      .home:hover .seg-name {
        background: #8d81f5;
      }

      .tabs {
        position: relative;
        z-index: 1;
        display: flex;
        align-items: stretch;
        min-width: 0;
        /* Tucks the first tab under the name segment's arrow. */
        margin: 0 0 0 calc(-1 * var(--arrow));
        padding: 0;
        list-style: none;
        overflow: hidden;
      }
      .tab {
        display: flex;
        align-items: center;
        gap: 0.4rem;
        padding: 0 0.75rem;
        white-space: nowrap;
        color: var(--dim);
        animation: flag 1.1s ease-out var(--at) both;
      }
      /* Whatever tab comes first sits partly under the arrow before it, so it
         gets that much more room on the left. */
      .tab:first-child {
        padding-left: calc(0.75rem + var(--arrow));
      }
      .tab.current {
        padding-right: calc(0.75rem + var(--arrow));
        color: var(--ink);
        background: var(--pane);
        clip-path: polygon(0 0, calc(100% - var(--arrow)) 0, 100% 50%, calc(100% - var(--arrow)) 100%, 0 100%);
      }
      .tab[data-to='blocked'] {
        --flag: color-mix(in srgb, var(--s-blocked) 30%, transparent);
      }

      /* Both glyphs occupy one grid cell, so the swap never shifts the tab. */
      .glyph {
        display: inline-grid;
        font-weight: 700;
      }
      .glyph > span {
        grid-area: 1 / 1;
      }
      .glyph .from {
        color: var(--s-working);
        animation: glyph-out 0.2s ease-in var(--at) both;
      }
      .glyph .to {
        animation: glyph-in 0.25s ease-out var(--at) both;
      }

      @keyframes glyph-out {
        from { opacity: 1; }
        to { opacity: 0; }
      }
      @keyframes glyph-in {
        from { opacity: 0; }
        to { opacity: 1; }
      }
      /* Only the blocked tab has a --flag colour; on every other tab this
         animates transparent to transparent and nothing is seen. */
      @keyframes flag {
        0% { background-color: transparent; }
        20% { background-color: var(--flag, transparent); }
        100% { background-color: transparent; }
      }
      .tab.current {
        animation: none;
      }

      .statusline nav {
        display: flex;
        align-items: center;
        gap: 0.25rem;
        margin-left: auto;
        padding: 0 var(--gutter) 0 1rem;
      }
      .statusline nav a {
        padding: 0.25rem 0.6rem;
        color: var(--text);
        text-decoration: none;
        border-radius: 4px;
      }
      .statusline nav a:hover {
        color: var(--ink);
        background: var(--pane);
      }

      @media (max-width: 52rem) {
        .tab:nth-child(n + 4) { display: none; }
      }
      @media (max-width: 36rem) {
        .tabs { display: none; }
        .statusline nav a.optional { display: none; }
      }

      /* ── Hero ────────────────────────────────────────────────────────── */
      .hero {
        position: relative;
        overflow: hidden;
        padding: clamp(4rem, 12vw, 8.5rem) 0 clamp(3.5rem, 8vw, 6rem);
        border-bottom: 1px solid var(--line);
      }
      /* A night sky, sparse enough to read as a sky and not as texture.
         Static: the status line is the page's one moment of motion. */
      .hero::before {
        content: '';
        position: absolute;
        inset: 0;
        background-image:
          radial-gradient(1.5px 1.5px at 12% 22%, #e0dcf5, transparent),
          radial-gradient(1px 1px at 27% 68%, #e0dcf5bb, transparent),
          radial-gradient(2px 2px at 41% 14%, #46dba7, transparent),
          radial-gradient(1px 1px at 55% 81%, #e0dcf5aa, transparent),
          radial-gradient(1.5px 1.5px at 63% 33%, #e0dcf5dd, transparent),
          radial-gradient(2px 2px at 78% 9%, #bd93f9, transparent),
          radial-gradient(1px 1px at 86% 58%, #e0dcf5bb, transparent),
          radial-gradient(1.5px 1.5px at 93% 26%, #e0dcf5dd, transparent),
          radial-gradient(1px 1px at 7% 84%, #e0dcf599, transparent),
          radial-gradient(2px 2px at 34% 44%, #25bbed, transparent),
          radial-gradient(1px 1px at 71% 71%, #e0dcf5aa, transparent),
          radial-gradient(1px 1px at 48% 52%, #e0dcf577, transparent),
          radial-gradient(1px 1px at 3% 41%, #e0dcf599, transparent),
          radial-gradient(1.5px 1.5px at 19% 6%, #e0dcf5cc, transparent),
          radial-gradient(1px 1px at 58% 4%, #e0dcf5aa, transparent),
          radial-gradient(1.5px 1.5px at 97% 88%, #d17915, transparent),
          radial-gradient(1px 1px at 38% 92%, #e0dcf588, transparent),
          radial-gradient(1px 1px at 82% 40%, #e0dcf5aa, transparent);
        pointer-events: none;
      }
      .owl {
        position: absolute;
        top: 50%;
        right: -6rem;
        width: min(46rem, 70vw);
        height: auto;
        transform: translateY(-50%);
        opacity: 0.07;
        /* Fades out toward the headline, so the two never sit on top of each
           other at full strength. */
        -webkit-mask-image: linear-gradient(to right, transparent 5%, #000 55%);
        mask-image: linear-gradient(to right, transparent 5%, #000 55%);
        pointer-events: none;
        user-select: none;
      }
      .hero .wrap {
        position: relative;
      }

      h1 {
        /* 17ch holds "Know which agent" on one line, so the headline breaks
           into two lines instead of leaving "you." alone on a third. */
        max-width: 17ch;
        margin: 0 0 1.75rem;
        font-size: clamp(2.5rem, 7.2vw, 5.5rem);
        font-weight: 700;
        line-height: 1;
        letter-spacing: -0.035em;
        color: var(--ink);
      }

      .lede {
        max-width: 36rem;
        margin: 0 0 2.25rem;
        font-size: clamp(1.0625rem, 1.6vw, 1.25rem);
        line-height: 1.6;
        color: var(--text);
      }

      .install {
        display: flex;
        align-items: stretch;
        /* Wide enough that the whole command shows on a desktop. Narrower
           screens scroll the command inside the box instead. */
        max-width: 57rem;
        background: var(--pane);
        border: 1px solid var(--line);
        border-radius: 6px;
        overflow: hidden;
      }
      .install code {
        flex: 1;
        min-width: 0;
        display: block;
        padding: 0.9rem 1rem;
        font-size: 0.875rem;
        background: none;
        border: 0;
        border-radius: 0;
        overflow-x: auto;
        scrollbar-width: thin;
      }
      .install .p {
        color: var(--violet);
        user-select: none;
      }
      .install button {
        flex: none;
        min-width: 6.5rem;
        padding: 0 1.1rem;
        font: inherit;
        font-size: 0.875rem;
        font-weight: 700;
        color: var(--ink);
        background: var(--line);
        border: 0;
        border-left: 1px solid var(--line);
        cursor: pointer;
      }
      .install button:hover {
        background: var(--violet);
        color: #fff;
      }
      .install button[data-state='copied'] {
        background: var(--s-done);
        color: var(--night);
      }

      .needs {
        max-width: 44rem;
        margin: 1rem 0 0;
        font-size: 0.9375rem;
        color: var(--dim);
      }

      /* ── The recording ───────────────────────────────────────────────── */
      .shot {
        position: relative;
        padding: clamp(3rem, 7vw, 5rem) 0;
        border-bottom: 1px solid var(--line);
      }
      .shot .frame {
        position: relative;
        max-width: 68rem;
        margin: 0 auto;
      }
      /* The owl's gradient, blurred into light behind the terminal. The only
         place the full gradient appears, so it reads as the owl and not as
         a decoration. */
      .shot .frame::before {
        content: '';
        position: absolute;
        inset: 8% 6%;
        background: linear-gradient(100deg, #46dba7, #25bbed 30%, #3288dd 50%, #7c6ff0 72%, #d17915);
        filter: blur(70px);
        opacity: 0.28;
        z-index: 0;
        pointer-events: none;
      }
      .shot img {
        position: relative;
        z-index: 1;
        display: block;
        width: 100%;
        height: auto;
        border: 1px solid var(--line);
        border-radius: 8px;
      }
      .caption {
        max-width: 40rem;
        margin: 1.25rem 0 0;
        font-size: 0.9375rem;
        line-height: 1.6;
        color: var(--dim);
      }

      /* ── Sections ────────────────────────────────────────────────────── */
      section.block {
        padding: clamp(3.5rem, 8vw, 6rem) 0;
        border-bottom: 1px solid var(--line);
      }
      h2 {
        margin: 0 0 0.75rem;
        font-size: clamp(1.625rem, 3vw, 2.25rem);
        font-weight: 700;
        line-height: 1.15;
        letter-spacing: -0.01em;
        color: var(--ink);
      }
      .section-lede {
        max-width: 38rem;
        margin: 0 0 2.5rem;
        font-size: 1.0625rem;
        line-height: 1.6;
        color: var(--dim);
      }

      /* What it does: text left, a picture of the result right. */
      .fix {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
        gap: clamp(1.5rem, 4vw, 4rem);
        align-items: center;
        padding: 2.5rem 0;
        border-top: 1px solid var(--line);
      }
      .fix:first-of-type {
        border-top: 0;
        padding-top: 0.5rem;
      }
      h3 {
        margin: 0 0 0.75rem;
        font-size: 1.25rem;
        font-weight: 700;
        line-height: 1.3;
        color: var(--ink);
      }
      .fix p {
        max-width: 34rem;
        margin: 0 0 1rem;
        line-height: 1.65;
      }
      .cmds {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
      }

      .term {
        margin: 0;
        padding: 1rem 1.1rem;
        font-size: 0.8125rem;
        line-height: 1.7;
        color: var(--text);
        background: var(--pane);
        border: 1px solid var(--line);
        border-radius: 6px;
      }
      pre.term {
        overflow-x: auto;
        white-space: pre;
      }
      .term .p {
        color: var(--violet);
        user-select: none;
      }
      .term .row {
        display: grid;
        grid-template-columns: 9.5rem 3rem 1fr;
        padding: 0.15rem 0.5rem;
        margin: 0 -0.5rem;
        border-left: 2px solid transparent;
      }
      .term .row.hot {
        background: var(--line);
        border-left-color: var(--s-blocked);
        color: var(--ink);
      }
      .widget-note {
        margin: 0.75rem 0 0 !important;
        font-size: 0.875rem;
        color: var(--dim);
      }

      .bars {
        display: grid;
        gap: 0.5rem;
      }
      .bar-label {
        margin: 0.5rem 0 0 !important;
        font-size: 0.8125rem;
        color: var(--dim);
      }
      .bar-label:first-child {
        margin-top: 0 !important;
      }
      .minibar {
        display: flex;
        flex-wrap: wrap;
        gap: 0.25rem 1rem;
        padding: 0.45rem 0.75rem;
        font-size: 0.8125rem;
        color: var(--dim);
        background: #1b1b1b;
        border: 1px solid #2c2c2c;
        border-radius: 4px;
      }
      .minibar.roosty {
        color: var(--text);
        background: var(--night);
        border-color: var(--line);
      }
      .minibar b {
        font-weight: 700;
      }
      .minibar .host {
        margin-left: auto;
        color: var(--dim);
      }

      /* Get running: the real sequence, beside the keys. */
      .split {
        display: grid;
        grid-template-columns: minmax(0, 1.35fr) minmax(0, 1fr);
        gap: clamp(2rem, 6vw, 5rem);
      }
      .steps {
        margin: 0;
        padding: 0;
        list-style: none;
        counter-reset: step;
      }
      .steps li {
        position: relative;
        padding: 0 0 1.5rem 2.5rem;
        counter-increment: step;
      }
      .steps li::before {
        content: counter(step);
        position: absolute;
        left: 0;
        top: 0.1rem;
        width: 1.6rem;
        height: 1.6rem;
        display: grid;
        place-items: center;
        font-size: 0.8125rem;
        font-weight: 700;
        color: var(--night);
        background: var(--lilac);
        border-radius: 50%;
      }
      /* The line joining the numbers is the sequence made visible. */
      .steps li:not(:last-child)::after {
        content: '';
        position: absolute;
        left: 0.8rem;
        top: 1.9rem;
        bottom: 0.3rem;
        width: 1px;
        background: var(--line);
      }
      .steps code {
        display: block;
        max-width: 100%;
        overflow-x: auto;
        padding: 0.45rem 0.7rem;
      }
      .steps p {
        margin: 0.45rem 0 0;
        font-size: 0.9375rem;
        color: var(--dim);
      }

      h3.side {
        margin-bottom: 1.25rem;
      }
      .keys {
        margin: 0;
      }
      .keys div {
        display: grid;
        grid-template-columns: 6.5rem 1fr;
        gap: 1rem;
        padding: 0.9rem 0;
        border-top: 1px solid var(--line);
      }
      .keys div:first-child {
        border-top: 0;
        padding-top: 0;
      }
      .keys dt {
        margin: 0;
      }
      .keys dd {
        margin: 0;
        line-height: 1.5;
      }

      /* Three ways: three columns sharing hairlines, smallest first. */
      .ways {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        margin: 0;
        padding: 0;
        list-style: none;
        border: 1px solid var(--line);
        border-radius: 8px;
        overflow: hidden;
      }
      .ways li {
        display: flex;
        flex-direction: column;
        gap: 0.75rem;
        padding: 1.5rem;
        border-left: 1px solid var(--line);
      }
      .ways li:first-child {
        border-left: 0;
      }
      .ways h3 {
        margin: 0;
      }
      .ways p {
        margin: 0;
        flex: 1;
        line-height: 1.6;
        color: var(--text);
      }
      .ways code {
        display: block;
        overflow-x: auto;
        padding: 0.45rem 0.7rem;
      }

      /* Works with your agent. */
      .agents {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0 clamp(1.5rem, 5vw, 4rem);
        margin: 0;
        padding: 0;
        list-style: none;
      }
      .agents li {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        align-items: baseline;
        gap: 0.25rem 1rem;
        padding: 1rem 0;
        border-top: 1px solid var(--line);
      }
      .agents .name {
        font-weight: 700;
        color: var(--ink);
      }
      .agents .how {
        grid-column: 1;
        font-size: 0.9375rem;
        color: var(--dim);
      }
      .agents code {
        grid-column: 2;
        grid-row: 1 / span 2;
        align-self: center;
      }
      .agents-note {
        max-width: 44rem;
        margin: 2rem 0 0;
        line-height: 1.65;
        color: var(--dim);
      }

      /* ── Closing ─────────────────────────────────────────────────────── */
      .closing {
        padding: clamp(4.5rem, 11vw, 8rem) 0;
      }
      .closing h2 {
        max-width: 18ch;
        margin-bottom: 2rem;
        font-size: clamp(2.25rem, 6vw, 4.25rem);
        line-height: 1.02;
        letter-spacing: -0.02em;
      }
      .closing .more {
        margin: 1.25rem 0 0;
      }

      /* ── Footer ──────────────────────────────────────────────────────── */
      footer {
        overflow: hidden;
        border-top: 1px solid var(--line);
      }
      .foot-links {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: 0.5rem 1.5rem;
        padding-top: 2rem;
        padding-bottom: 2rem;
        font-size: 0.9375rem;
      }
      .foot-links a {
        color: var(--text);
        text-decoration: none;
      }
      .foot-links a:hover {
        color: var(--ink);
        text-decoration: underline;
      }
      .foot-links .credit {
        margin-left: auto;
        color: var(--dim);
      }
      .foot-links .credit a {
        color: var(--dim);
        text-decoration: underline;
      }
      /* The name, as large as the page is wide, sunk into the dark. It sits
         on the very bottom edge so its descenders-free baseline is cut clean. */
      .wordmark {
        display: block;
        margin: 0 0 -0.14em;
        padding: 0 var(--gutter);
        font-size: clamp(6rem, 31vw, 29rem);
        font-weight: 700;
        line-height: 0.8;
        letter-spacing: -0.04em;
        color: var(--pane);
        user-select: none;
      }

      /* ── Narrow screens ──────────────────────────────────────────────── */
      @media (max-width: 52rem) {
        .fix,
        .split {
          grid-template-columns: minmax(0, 1fr);
        }
        .ways {
          grid-template-columns: minmax(0, 1fr);
        }
        .ways li {
          border-left: 0;
          border-top: 1px solid var(--line);
        }
        .ways li:first-child {
          border-top: 0;
        }
        .agents {
          grid-template-columns: minmax(0, 1fr);
        }
        .owl {
          right: -12rem;
          opacity: 0.07;
        }
      }
      @media (max-width: 36rem) {
        .term .row {
          grid-template-columns: 7.5rem 2.5rem 1fr;
        }
        .foot-links .credit {
          margin-left: 0;
          width: 100%;
        }
      }

      /* ── Reduced motion: the settled fleet, with nothing moving ──────── */
      @media (prefers-reduced-motion: reduce) {
        .tab,
        .glyph .from,
        .glyph .to {
          animation: none;
        }
        .glyph .from {
          display: none;
        }
      }
    `,
  ];

  private async copy(which: 'hero' | 'closing') {
    try {
      await navigator.clipboard.writeText(INSTALL_CMD);
      this.copied = which;
    } catch {
      // No clipboard access (an insecure origin, or a denied permission).
      // Select the command instead, so Cmd-C or Ctrl-C finishes the job, and
      // say that is what happened rather than claiming a copy.
      const code = this.renderRoot.querySelector(`#install-${which}`);
      const sel = window.getSelection();
      if (code && sel) {
        const range = document.createRange();
        range.selectNodeContents(code);
        sel.removeAllRanges();
        sel.addRange(range);
      }
      this.copied = `${which}-selected`;
    }
    const was = this.copied;
    setTimeout(() => {
      if (this.copied === was) this.copied = '';
    }, 2000);
  }

  private install(which: 'hero' | 'closing') {
    const label = this.copied === which ? 'Copied' : this.copied === `${which}-selected` ? 'Selected' : 'Copy';
    return html`
      <div class="install mono">
        <code id="install-${which}"><span class="p" aria-hidden="true">$ </span>${INSTALL_CMD}</code>
        <button
          type="button"
          data-state=${this.copied === which ? 'copied' : ''}
          aria-label=${label === 'Copy' ? 'Copy the install command' : label}
          @click=${() => this.copy(which)}
        >
          <span aria-live="polite">${label}</span>
        </button>
      </div>
    `;
  }

  override render() {
    const data = this.serverData as SplashData | null;
    const { nav = [] } = data ?? {};
    const docs = nav.find((n) => n.href.startsWith('/docs/getting-started'))?.href ?? '/docs/getting-started';

    return html`
      <!-- A roost status line. The owl and name segments are the home link, the tabs
           are a fleet settling into its states, and the right side is the
           site's navigation. The tabs are a picture, so assistive tech is
           told what they show once rather than read five glyphs. -->
      <header class="statusline mono">
        <a class="home" href="/">
          <span class="seg seg-owl"><img src="/logo.png" alt="" width="22" height="22" /></span>
          <span class="seg seg-name site-title">roost</span>
        </a>
        <ol class="tabs" role="img" aria-label="Five agents: api is done, web is working, worker is blocked, docs is idle, tests has an error.">
          ${FLEET.map(
            (t) => html`
              <li
                class="tab ${t.current ? 'current' : ''}"
                data-to=${t.to}
                style="--at:${t.at}s"
                aria-hidden="true"
              >
                <span class="glyph">
                  ${t.to === 'working'
                    ? html`<span class="s-working">${GLYPH.working}</span>`
                    : html`<span class="from">${GLYPH.working}</span><span class="to s-${t.to}">${GLYPH[t.to]}</span>`}
                </span>
                <span>${t.n} ${t.name}</span>
              </li>
            `,
          )}
        </ol>
        <nav aria-label="Main navigation">
          ${nav.map(
            (item) => html`<a
              class=${item.href.startsWith('http') ? 'optional' : ''}
              href=${item.href}
            >${item.label}</a>`,
          )}
        </nav>
      </header>

      <main>
        <section class="hero">
          <img class="owl" src="/logo.png" alt="" width="512" height="517" aria-hidden="true" />
          <div class="wrap">
            <h1>Know which agent needs you.</h1>
            <p class="lede">
              roost runs your coding agents on a tmux server of its own, and every
              tab carries a badge with what that agent is doing. The badge comes
              from the agent, so it is never a guess.
            </p>
            ${this.install('hero')}
            <p class="needs">
              Needs tmux 3.2 or newer and git. There is no daemon and no binary,
              just a launcher, a tmux config and some shell scripts.
            </p>
          </div>
        </section>

        <!-- Recorded, not screenshotted: demo/roost-hero.tape drives a real
             fleet built by demo/seed-fleet.sh on a throwaway roost server, so
             re-recording is one command and nothing of the author's machine is
             in the frame. Sized 1800x620, the real file, so its space is
             reserved before it loads. -->
        <section class="shot">
          <div class="wrap">
            <div class="frame">
              <img
                src="/roost-hero.png"
                alt="A roost session with five agent windows across the top, each badged with its state. An agent has answered in the pane behind, and the agent switcher lists all five with their states and how long each has been there."
                width="1800"
                height="620"
                decoding="async"
              />
            </div>
            <p class="caption">
              A real session. The switcher lists every agent with its state and
              how long it has been there, and the agent behind it has just
              answered.
            </p>
          </div>
        </section>

        <section class="block">
          <div class="wrap">
            <h2>What it does</h2>
            <p class="section-lede">Four things that change once your agents run in roost.</p>
            ${FIXES.map(
              (f) => html`
                <article class="fix">
                  <div>
                    <h3>${f.title}</h3>
                    <p>${f.fix}</p>
                    <div class="cmds">${f.cmds.map((c) => html`<code>${c}</code>`)}</div>
                  </div>
                  <div class="mono">${f.widget()}</div>
                </article>
              `,
            )}
          </div>
        </section>

        <section class="block">
          <div class="wrap split">
            <div>
              <h2>Get running</h2>
              <p class="section-lede">Four commands, in this order.</p>
              <ol class="steps">
                ${INSTALL_STEPS.map(
                  (s) => html`<li><code>${s.cmd}</code><p>${s.note}</p></li>`,
                )}
              </ol>
            </div>
            <div>
              <h3 class="side">Keys worth knowing</h3>
              <dl class="keys">
                ${KEY_HINTS.map(
                  (k) => html`<div><dt><kbd>${k.keys}</kbd></dt><dd>${k.what}</dd></div>`,
                )}
              </dl>
              <p class="widget-note">The prefix is <kbd>Ctrl-s</kbd>, so your own tmux prefix still works.</p>
            </div>
          </div>
        </section>

        <section class="block">
          <div class="wrap">
            <h2>Three ways to run a fleet</h2>
            <p class="section-lede">Start with the first. They all use the same commands, so moving up is not a rewrite.</p>
            <ol class="ways">
              ${FLEET_SHAPES.map(
                (w) => html`<li><h3>${w.title}</h3><p>${w.what}</p><code>${w.cmd}</code></li>`,
              )}
            </ol>
            <p class="agents-note">
              <a href="/docs/driving-a-fleet">Driving a fleet</a> has every command, with its exit codes.
            </p>
          </div>
        </section>

        <section class="block">
          <div class="wrap">
            <h2>Works with your agent</h2>
            <p class="section-lede">Badges come from the agent, so any harness can drive them.</p>
            <ul class="agents">
              ${AGENTS.map(
                (a) => html`<li><span class="name">${a.name}</span><span class="how">${a.how}</span><code>${a.cmd}</code></li>`,
              )}
            </ul>
            <!-- The two examples are the two real limits and both are stated
                 the same way on /docs/state-badges -- if that page and this
                 paragraph ever disagree, this one is wrong. -->
            <p class="agents-note">
              ${ADAPTER_COUNT} adapters ship in the repo, and each one badges its
              pane and records its reply on its own. Claude Code and opencode are
              wired automatically in roost's own panes; the rest take one
              <code>roost install</code>. What each can signal is not identical:
              Codex has no error signal to pass on, and pi never asks permission,
              so a pi pane never blocks.
              <a href="/docs/state-badges">Every harness's exact badge table</a>.
            </p>
            ${
              // Every harness that was ever on this list now ships, so the list
              // is empty and the sentence would read "planned for ." Rendered
              // conditionally rather than deleted: the array stays as the one
              // place to name the next one.
              AGENTS_PLANNED.length
                ? html`<p class="agents-note">Dedicated adapters planned for ${AGENTS_PLANNED.join(', ')}.</p>`
                : ''
            }
          </div>
        </section>

        <section class="closing">
          <div class="wrap">
            <h2>Give every agent a tab of its own.</h2>
            ${this.install('closing')}
            <p class="more">
              New to it? <a href=${docs}>Start with getting started</a>.
            </p>
          </div>
        </section>
      </main>

      <footer>
        <div class="wrap foot-links">
          ${nav.map((item) => html`<a href=${item.href}>${item.label}</a>`)}
          <a href="/llms.txt">llms.txt</a>
          <span class="credit">MIT licence. Built with <a href="https://litro.dev" rel="noopener">Litro</a>.</span>
        </div>
        <span class="wordmark mono" aria-hidden="true">roost</span>
      </footer>
    `;
  }
}

export default SplashPage;

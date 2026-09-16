export const siteConfig = {
  title: 'roost',
  description:
    'An on-demand tmux agent view. Every coding agent reports its own state on its tab, on a tmux server kept apart from yours.',
  logo: null,
  editUrlBase: 'https://github.com/beatzball/roost/edit/main/site/content/docs',
  nav: [
    { label: 'Docs', href: '/docs/getting-started' },
    // A visitor deciding whether a tool is alive looks for this before they
    // look at the docs. Generated from CHANGELOG.md -- see
    // scripts/sync-changelog.mjs.
    { label: 'Changelog', href: '/docs/changelog' },
    { label: 'GitHub', href: 'https://github.com/beatzball/roost' },
  ],
  sidebar: [
    {
      label: 'Start Here',
      items: [
        { label: 'Getting Started',  slug: 'getting-started' },
        { label: 'Setup and Settings', slug: 'setup' },
        { label: 'State Badges',     slug: 'state-badges' },
      ],
    },
    {
      label: 'Guides',
      items: [
        { label: 'Using roost',     slug: 'using-roost' },
        { label: 'Driving a Fleet', slug: 'driving-a-fleet' },
        { label: 'Extensions',      slug: 'extensions' },
        { label: 'Writing an Extension', slug: 'writing-an-extension' },
      ],
    },
    {
      label: 'Reference',
      items: [
        { label: 'How It Works',    slug: 'how-it-works' },
        { label: 'Troubleshooting', slug: 'troubleshooting' },
        { label: 'Changelog',       slug: 'changelog' },
      ],
    },
  ],
};

export default siteConfig;

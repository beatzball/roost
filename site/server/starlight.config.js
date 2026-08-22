export const siteConfig = {
  title: 'roost',
  description:
    'An on-demand tmux agent view for wrangling multiple AI coding agents — without giving up your normal tmux setup.',
  logo: null,
  editUrlBase: 'https://github.com/beatzball/roost/edit/main/site/content/docs',
  nav: [
    { label: 'Docs', href: '/docs/getting-started' },
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
      ],
    },
    {
      label: 'Reference',
      items: [
        { label: 'How It Works',    slug: 'how-it-works' },
        { label: 'Troubleshooting', slug: 'troubleshooting' },
      ],
    },
  ],
};

export default siteConfig;

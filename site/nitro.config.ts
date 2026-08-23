import { defineNitroConfig } from 'nitropack/config';
import type { Nitro } from 'nitropack';
import { resolve } from 'node:path';
import { ssgPreset } from '@beatzball/litro/config';
import pagesPlugin from '@beatzball/litro/plugins';
import ssgPlugin from '@beatzball/litro/plugins/ssg';
import ogPlugin, { ogPrerenderHook } from '@beatzball/litro/plugins/og';
import contentPlugin from '@beatzball/litro/content/plugin';

export default defineNitroConfig({
  ...ssgPreset(),

  srcDir: 'server',

  publicAssets: [
    { dir: '../dist/client', baseURL: '/_litro/', maxAge: 31536000 },
    { dir: '../public',      baseURL: '/',        maxAge: 0 },
    { dir: '../content',     baseURL: '/content/', maxAge: 86400 },
    { dir: '../node_modules/@shoelace-style/shoelace/dist/assets', baseURL: '/shoelace/assets/', maxAge: 604800 },
    { dir: '../node_modules/@shoelace-style/shoelace/dist/themes', baseURL: '/shoelace/themes/', maxAge: 604800 },
  ],

  externals: { inline: ['@lit-labs/ssr', '@lit-labs/ssr-client', 'satori'] },

  esbuild: {
    options: {
      tsconfigRaw: {
        compilerOptions: {
          experimentalDecorators: true,
          useDefineForClassFields: false,
        },
      },
    },
  },

  ignore: ['**/middleware/vite-dev.ts'],
  handlers: [
    {
      middleware: true,
      handler: resolve('./server/middleware/vite-dev.ts'),
      env: 'dev',
    },
  ],

  hooks: {
    // Must be registered here, at config level, and NOT inside build:before:
    // Nitro's CLI runs prerender() before build(), so a hook added later
    // never fires and no OG image is ever written.
    'prerender:routes': ogPrerenderHook(),
    'build:before': async (nitro: Nitro) => {
      await contentPlugin(nitro);
      await pagesPlugin(nitro);
      await ssgPlugin(nitro);
      await ogPlugin(nitro, { siteName: 'roost' });
    },
  },

  compatibilityDate: '2025-01-01',

  routeRules: {
    '/_litro/**': {
      headers: { 'cache-control': 'public, max-age=31536000, immutable' },
    },
  },
});

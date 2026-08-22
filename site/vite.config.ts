import { defineConfig } from 'vite';
import litroContentPlugin from '@beatzball/litro/vite';

export default defineConfig({
  plugins: [litroContentPlugin()],
  base: process.env.LITRO_BASE_PATH ? `${process.env.LITRO_BASE_PATH}/_litro/` : '/_litro/',
  resolve: {
    // No 'source' condition here. An installed package's TypeScript is never
    // transpiled by Vite (it lives under node_modules), so resolving a package
    // to its source emits raw decorators and the client bundle fails to parse.
    // @beatzball/litro stopped publishing that condition in 0.13.1, and the
    // recipe templates dropped it too; this line matches the current template.
    conditions: ['browser', 'module', 'import', 'default'],
  },
  build: {
    outDir: 'dist/client',
    rollupOptions: {
      input: 'app.ts',
      output: {
        entryFileNames: '[name].js',
      },
    },
  },
});

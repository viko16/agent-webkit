import { createServer } from 'vite';
import { randomUUID } from 'node:crypto';
import { appendFileSync } from 'node:fs';

// Reuse the locked test-only Vite dependency; serve a disposable project copy.
const nonce = randomUUID();
const record = event => appendFileSync(process.env.VITE_WORKFLOW_LOG,
  JSON.stringify({ time: Date.now(), ...event }) + '\n');
const server = await createServer({
  configFile: false,
  root: process.env.VITE_PROJECT_ROOT,
  server: {
    host: '127.0.0.1', port: 0, allowedHosts: ['example.com'],
    ws: { protocol: 'wss', host: 'example.com', clientPort: 443 },
  },
  plugins: [{
    name: 'proxy-workflow-evidence',
    configureServer(vite) {
      vite.middlewares.use((req, res, next) => {
        res.on('finish', () => record({ kind: 'http', path: req.url, status: res.statusCode }));
        if (req.url?.split('?')[0] !== '/api/probe') return next();
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ nonce }));
      });
      vite.httpServer.on('upgrade', req => record({ kind: 'upgrade', path: req.url }));
      vite.ws.on('connection', () => record({ kind: 'ws-connected' }));
      vite.ws.on('workflow:applied', data => record({
        kind: 'hmr-applied', revision: data.revision, documentId: data.documentId,
      }));
    },
  }],
});
await server.listen();
console.log(`VITE_URL=http://127.0.0.1:${server.httpServer.address().port}/`);
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, async () => { await server.close(); process.exit(0); });
}

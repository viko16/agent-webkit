import { createServer } from 'vite';
import { randomUUID } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const nonce = randomUUID();
const server = await createServer({
  root: dirname(fileURLToPath(import.meta.url)),
  define: { __VUE_OPTIONS_API__: true, __VUE_PROD_DEVTOOLS__: false, __VUE_PROD_HYDRATION_MISMATCH_DETAILS__: false },
  server: { host: '127.0.0.1', port: 0 },
  plugins: [{
    name: 'form-submission-fixture',
    configureServer(vite) {
      vite.middlewares.use((req, res, next) => {
        if (req.url === '/api/health') {
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ nonce }));
          return;
        }
        if (req.url !== '/api/save' || req.method !== 'POST') return next();
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
          const fields = JSON.parse(body);
          const accepted = fields.text !== 'reject';
          const record = { nonce, fields, accepted };
          appendFileSync(process.env.FORM_LOG, JSON.stringify(record) + '\n');
          setTimeout(() => {
            res.statusCode = accepted ? 200 : 422;
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify(record));
          }, 150);
        });
      });
    }
  }]
});
await server.listen();
console.log(`FORM_URL=http://127.0.0.1:${server.httpServer.address().port}/`);
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, async () => { await server.close(); process.exit(0); });
}

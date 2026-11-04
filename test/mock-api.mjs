// A stand-in for the parts of the Provelox API the action talks to, with the real response shapes:
//   POST /v1/ci/deploy      202 { app, version, image }          errors are { error: { code, message } }
//   GET  /v1/ci/deployment  200 { app, version, image, isBuilding, isFailed, lines, ... }, or, when Provelox has no record
//                           of a deploy (it was restarted), { app, isBuilding: false, isFailed: false, lines: [] }
// usage: node test/mock-api.mjs <port> <scenario>
import http from 'node:http';

const [port, scenario] = [Number(process.argv[2]), process.argv[3] ?? 'ok'];
const KEY = 'pvxk_test_secret';
let version = 0;
let image = '';
let polls = 0;

const send = (res, code, body, type = 'application/json') => {
  res.writeHead(code, { 'content-type': type });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
};
const err = (res, code, status, message) => send(res, status, { error: { code, message } });

http
  .createServer((req, res) => {
    if (req.headers.authorization !== `Bearer ${KEY}`) return err(res, 'unauthorized', 401, 'Invalid API key');
    if (scenario === 'hang') return; // accepts the request and never answers
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      if (req.method === 'POST' && req.url === '/v1/ci/deploy') {
        const wanted = JSON.parse(raw || '{}').image ?? '';
        if (wanted.startsWith('other/'))
          return err(res, 'forbidden', 403, 'This key or token can deploy another version of the image the app runs, not a different image.');
        image = wanted;
        version += 1;
        polls = 0;
        return send(res, 202, { app: 'demo', version, image });
      }
      if (req.method === 'GET' && req.url === '/v1/ci/deployment') {
        polls += 1;
        const state = (over) => ({ app: 'demo', version, image, isBuilding: false, isFailed: false, startedAt: 'x', lines: [`Deploying ${image} (version ${version})`], ...over });
        if (scenario === 'ok')
          return send(res, 200, polls < 2 ? state({ isBuilding: true, lines: [`Deploying ${image} (version ${version})`, 'Starting: 1/2 instances running…'] })
            : state({ lines: [`Deploying ${image} (version ${version})`, 'Starting: 1/2 instances running…', 'Running: 2/2 instances.'] }));
        if (scenario === 'rollback')
          return send(res, 200, state({ isFailed: true, lines: [`Deploying ${image} (version ${version})`, 'Docker rolled the update back: the new version did not start.'] }));
        if (scenario === 'restarted') // what Provelox answers when it has forgotten the deploy
          return send(res, 200, polls < 2 ? state({ isBuilding: true }) : { app: 'demo', isBuilding: false, isFailed: false, lines: [] });
        if (scenario === 'replaced') return send(res, 200, state({ version: version + 1, isBuilding: false }));
        if (scenario === 'building') return send(res, 200, state({ isBuilding: true, lines: ['Starting: 0/1 instances running…'] }));
        if (scenario === 'blip') // a proxy in front of Provelox is restarting for a moment
          return polls <= 2 ? send(res, 502, '<html>Bad gateway</html>', 'text/html') : send(res, 200, state());
        if (scenario === 'gone') return send(res, 502, '<html>Bad gateway</html>', 'text/html');
        if (scenario === 'revoked') return polls < 2 ? send(res, 200, state({ isBuilding: true })) : err(res, 'unauthorized', 401, 'Invalid API key');
      }
      err(res, 'not_found', 404, 'Not found');
    });
  })
  .listen(port, '127.0.0.1', () => console.log('mock ready'));

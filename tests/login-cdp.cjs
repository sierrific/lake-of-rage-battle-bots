// Servidor CDP sintetico: sem navegador, internet ou credenciais reais.
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const vm = require('node:vm');
const assertion = 'b'.repeat(256) + ',contateste,10,123,sim3.psim.us;' + 'c'.repeat(256);
const server = http.createServer((req, res) => {
  const port = server.address().port;
  const page = (url, ws) => ({type: 'page', url, webSocketDebuggerUrl: ws});
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify([
    page('https://play.pokemonshowdown.com.evil.test/', `ws://127.0.0.1:${port}/bad`),
    page('https://play.pokemonshowdown.com/', 'ws://remote.test:123/bad'),
    page('https://play.pokemonshowdown.com/', `ws://127.0.0.1:${port}/test`),
  ]));
});
function frame(text, opcode = 1, final = true) {
  const body = Buffer.from(text);
  const header = Buffer.alloc(body.length < 126 ? 2 : 4);
  header[0] = (final ? 128 : 0) | opcode;
  header[1] = body.length < 126 ? body.length : 126;
  if (body.length >= 126) header.writeUInt16BE(body.length, 2);
  return Buffer.concat([header, body]);
}
server.on('upgrade', (req, socket) => {
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] +
    '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let input = Buffer.alloc(0);
  socket.on('error', () => {});
  socket.on('data', async chunk => {
    input = Buffer.concat([input, chunk]);
    if (input.length < 6) return;
    const opcode = input[0] & 15;
    if (opcode !== 1) return;
    let size = input[1] & 127, offset = 2;
    if (size === 126) { size = input.readUInt16BE(2); offset = 4; }
    if (size === 127) return socket.destroy();
    if (input.length < offset + 4 + size) return;
    const mask = input.subarray(offset, offset + 4);
    const data = Buffer.from(input.subarray(offset + 4, offset + 4 + size));
    data.forEach((byte, i) => { data[i] = byte ^ mask[i % 4]; });
    input = Buffer.alloc(0);
    let reply;
    try {
      const message = JSON.parse(data.toString());
      if (message.method === 'test.close') return socket.end(frame('', 8));
      if (message.method === 'test.error') reply = {id: message.id, error: {message: 'sintetico'}};
      else if (message.method === 'test.exception') reply = {id: message.id, result: {exceptionDetails: {text: 'sintetico'}}};
      else if (message.method === 'Runtime.evaluate') {
        const mode = message.params.testState;
        let calls = 0;
        const user = {userid: mode === 'wrong' ? 'outraconta' : 'contateste', named: mode !== 'guest'};
        const context = {URLSearchParams, location: {origin: mode === 'origin' ? 'https://example.org' : 'https://play.pokemonshowdown.com'},
          window: mode === 'old' ? {app: {user: {get: key => user[key]}}} : {PS: {user}},
          fetch: async (url, opts) => {
            calls++;
            assert.equal(url, '/~~showdown/action.php');
            assert.equal(opts.method, 'POST');
            assert.equal(opts.credentials, 'same-origin');
            assert.equal(opts.redirect, 'error');
            assert.deepEqual(Object.fromEntries(new URLSearchParams(opts.body)),
              {act: 'getassertion', userid: 'contateste', challstr: message.params.testChallenge});
            return {ok: mode !== 'http', text: async () => mode === 'html' ? '<html>erro</html>' : assertion};
          }};
        const value = await vm.runInNewContext(message.params.expression, context, {timeout: 1000});
        assert.equal(calls, ['wrong', 'guest', 'origin'].includes(mode) ? 0 : 1);
        reply = {id: message.id, result: {result: {value}}};
      } else reply = {id: message.id, result: {echo: message.params.text}};
    } catch (error) {
      process.stderr.write(String(error) + '\n');
      reply = {id: 1, error: {message: 'fixture failed'}};
    }
    // Evento nao solicitado e mensagem fragmentada (inclusive texto Unicode).
    socket.write(frame(JSON.stringify({method: 'test.event'})));
    const text = JSON.stringify(reply), middle = Math.floor(text.length / 2);
    socket.write(frame(text.slice(0, middle), 1, false));
    socket.write(frame(text.slice(middle), 0));
  });
});
server.listen(0, '127.0.0.1', () => process.stdout.write(server.address().port + '\n'));
process.stdin.resume();
process.stdin.on('end', () => server.close(() => process.exit()));

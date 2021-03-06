/*jshint esversion: 6 */

const tls = require('tls');
const net = require('net');
const url = require('url');

const WebSocket = require('ws');

const PROXY_PASS = process.env.PROXY_PASS || '';
const PROXY_PORT = +process.env.PROXY_PORT || 6676;

const wss = new WebSocket.Server({ port: PROXY_PORT });
console.log(`WebSocket proxy listening on ${PROXY_PORT}`);

wss.on('connection', function connection(ws) {
    let query = url.parse(ws.upgradeReq.url, true).query;
    const required = ['host', 'port'];

    for (let i in required) {
        if (!query[required[i]])
            return ws.send(`missing required param ${required[i]}`);
    }

    if (PROXY_PASS && query.proxyPass != PROXY_PASS) {
        return ws.send(`Bad password`);
    }

    let socket;

    // This is a TLS connection
    if (query.port.startsWith('+')) {
        socket = tls.connect({
            host: query.host,
            port: +query.port,
            rejectUnauthorized: false
        }, () => {
            console.log('[TLS] connected to', query.host, query.port);
        });
    } else {
        socket = new net.Socket();
        socket.connect(+query.port, query.host, () => {
            console.log('connected to', query.host, query.port);
        });
    }

    socket.setEncoding('utf8')
        .on('data', (data) => {
            data.trim().split(/[\r\n]+/g).forEach(line => {
                console.log('<--', line);
                ws.send(line + '\n');
            });
        })
        .on('end', () => { ws.close(); });

    // TODO: Maybe this can be replaced by 001?
    ws.send('*CONNECTED\n');

    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('close', () => socket.destroy());

    ws.on('message', function incoming(message) {
        message.split(/[\r\n]+/).forEach(line => {
            console.log('-->', line);

            if (line === '*PING') {
                ws.send('*PONG\n');
                return;
            }

            socket.write(line + '\n');
        });
    });
});


// Clear out dead connections
setInterval(() => {
    wss.clients.forEach((ws) => {
        if (!ws.isAlive) {
            ws.terminate();
        } else {
            ws.isAlive = false;
            ws.ping('', false, true);
        }
    });
}, 15 * 1000);

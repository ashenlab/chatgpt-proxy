import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bridgeScript = path.join(root, "socks-http-bridge.mjs");

function listen(server, port = 0) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address().port);
    });
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function readUntil(socket, predicate, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    const timer = setTimeout(() => finish(new Error("timed out waiting for socket data")), timeoutMs);

    function finish(error) {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", onError);
      if (error) reject(error);
      else resolve(buffer);
    }

    function onData(chunk) {
      buffer = Buffer.concat([buffer, chunk]);
      if (predicate(buffer)) finish();
    }

    function onError(error) {
      finish(error);
    }

    socket.on("data", onData);
    socket.on("error", onError);
  });
}

async function waitForPort(port, child) {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    assert.equal(child.exitCode, null, "bridge exited before listening");
    const connected = await new Promise((resolve) => {
      const socket = net.connect({ host: "127.0.0.1", port });
      socket.once("connect", () => {
        socket.destroy();
        resolve(true);
      });
      socket.once("error", () => resolve(false));
    });
    if (connected) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`bridge did not listen on ${port}`);
}

function startBridge(bridgePort, socksPort) {
  return spawn(process.execPath, [bridgeScript], {
    env: {
      ...process.env,
      BRIDGE_LISTEN_HOST: "127.0.0.1",
      BRIDGE_LISTEN_PORT: String(bridgePort),
      UPSTREAM_SOCKS: `socks5://127.0.0.1:${socksPort}`,
      BRIDGE_WATCH_PARENT: "0",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function stopChild(child) {
  if (child.exitCode !== null) return Promise.resolve();
  child.kill("SIGTERM");
  return new Promise((resolve) => child.once("exit", resolve));
}

async function main() {
  let requestedHost = "";
  let requestedPort = 0;
  const socksServer = net.createServer((socket) => {
    let stage = "greeting";
    let buffer = Buffer.alloc(0);

    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (stage === "greeting" && buffer.length >= 3) {
        assert.deepEqual([...buffer.subarray(0, 3)], [0x05, 0x01, 0x00]);
        buffer = buffer.subarray(3);
        socket.write(Buffer.from([0x05, 0x00]));
        stage = "request";
      }
      if (stage === "request" && buffer.length >= 7) {
        assert.equal(buffer[3], 0x03, "bridge must send the target as a SOCKS5 domain");
        const hostLength = buffer[4];
        const requestLength = 7 + hostLength;
        if (buffer.length < requestLength) return;
        requestedHost = buffer.subarray(5, 5 + hostLength).toString();
        requestedPort = buffer.readUInt16BE(5 + hostLength);
        buffer = buffer.subarray(requestLength);
        socket.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]));
        stage = "tunnel";
      }
      if (stage === "tunnel" && buffer.length > 0) {
        socket.write(buffer);
        buffer = Buffer.alloc(0);
      }
    });
  });

  const socksPort = await listen(socksServer);
  const reservation = net.createServer();
  const bridgePort = await listen(reservation);
  await close(reservation);
  const bridge = startBridge(bridgePort, socksPort);

  try {
    await waitForPort(bridgePort, bridge);

    const client = net.connect({ host: "127.0.0.1", port: bridgePort });
    await new Promise((resolve) => client.once("connect", resolve));
    client.write("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n");
    const connected = await readUntil(client, (data) => data.includes("\r\n\r\n"));
    assert.match(connected.toString("latin1"), /^HTTP\/1\.1 200 /);
    assert.equal(requestedHost, "example.com");
    assert.equal(requestedPort, 443);

    client.write("ping");
    const echoed = await readUntil(client, (data) => data.includes("ping"));
    assert.equal(echoed.toString(), "ping");
    client.destroy();

    const invalid = net.connect({ host: "127.0.0.1", port: bridgePort });
    await new Promise((resolve) => invalid.once("connect", resolve));
    invalid.write("CONNECT example.com:nope HTTP/1.1\r\n\r\n");
    const rejected = await readUntil(invalid, (data) => data.includes("\r\n\r\n"));
    assert.match(rejected.toString("latin1"), /^HTTP\/1\.1 400 /);
    invalid.destroy();
    assert.equal(bridge.exitCode, null, "a malformed request must not stop the bridge");
  } finally {
    await stopChild(bridge);
    await close(socksServer);
  }

  const blocker = net.createServer();
  const blockedPort = await listen(blocker);
  const blockedBridge = startBridge(blockedPort, socksPort);
  const blockedExit = await new Promise((resolve) => blockedBridge.once("exit", resolve));
  assert.notEqual(blockedExit, 0, "bridge must fail when its port is already occupied");
  await close(blocker);

  console.log("bridge integration tests passed");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

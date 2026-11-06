import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const launchScript = path.join(root, ".build", "ChatGPT Proxy.app", "Contents", "Resources", "chatgpt-proxy-launch.sh");

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address().port);
    });
  });
}

function run(executable, environment) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, [], {
      env: { ...process.env, ...environment },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

async function main() {
  let proxyRequest = "";
  const proxyServer = net.createServer((socket) => {
    let request = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      request = Buffer.concat([request, chunk]);
      if (!request.includes("\r\n\r\n")) return;
      proxyRequest = request.toString("latin1");
      socket.end("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
    });
  });
  const proxyPort = await listen(proxyServer);
  const temporaryDirectory = await fs.promises.mkdtemp(path.join(os.tmpdir(), "chatgpt-proxy-http-test-"));
  const configPath = path.join(temporaryDirectory, "chatgpt-proxy.conf");
  const missingApp = path.join(temporaryDirectory, "Missing ChatGPT.app");
  await fs.promises.writeFile(configPath, [
    'ACTIVE_PROXY="http_test"',
    `CHATGPT_APP_PATH="${missingApp}"`,
    "PROXY_IDS=(http_test)",
    'PROXY_HTTP_TEST_NAME="HTTP test"',
    'PROXY_HTTP_TEST_TYPE="http"',
    'PROXY_HTTP_TEST_HOST="127.0.0.1"',
    `PROXY_HTTP_TEST_PORT="${proxyPort}"`,
    'PROXY_HTTP_TEST_USERNAME="test-user"',
    'PROXY_HTTP_TEST_PASSWORD="test-password"',
    // Older configurations may still contain this flag. HTTP mode must ignore it.
    'PROXY_HTTP_TEST_HTTP_BRIDGE="1"',
    'HTTP_BRIDGE_HOST="127.0.0.1"',
    `HTTP_BRIDGE_PORT="${proxyPort}"`,
    'BYPASS_ITEMS=("localhost" "127.0.0.1" "::1")',
    "",
  ].join("\n"), { mode: 0o600 });

  try {
    const result = await run(launchScript, {
      CHATGPT_PROXY_SKIP_UI: "1",
      CHATGPT_PROXY_CONFIG_FILE: configPath,
      CHATGPT_PROXY_PREFLIGHT_VERIFIED: "0",
      CHATGPT_PROXY_PREFLIGHT_URL: "http://preflight.example/check",
    });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /Cannot find ChatGPT executable/);
    assert.match(proxyRequest, /^GET http:\/\/preflight\.example\/check HTTP\/1\.1/m);
    assert.match(proxyRequest, new RegExp(`^Proxy-Authorization: Basic ${Buffer.from("test-user:test-password").toString("base64")}$`, "m"));
  } finally {
    await new Promise((resolve) => proxyServer.close(resolve));
    await fs.promises.rm(temporaryDirectory, { recursive: true, force: true });
  }

  console.log("HTTP launcher preflight test passed");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

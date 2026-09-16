import { createSign } from "node:crypto";
import http2 from "node:http2";

/// Apple wants a signed assertion rather than a key, and it is good for an
/// hour; one is made per run, which is well inside that.
function assertion({ key, keyId, teamId }) {
  const header = { alg: "ES256", kid: keyId };
  const claims = { iss: teamId, iat: Math.floor(Date.now() / 1000) };
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const signing = `${encode(header)}.${encode(claims)}`;
  const signature = createSign("SHA256").update(signing).sign({ key, dsaEncoding: "ieee-p1363" });
  return `${signing}.${signature.toString("base64url")}`;
}

/// One connection per host, because a run sends to every phone at once and
/// APNs would rather not be opened to once per phone.
function connect(host) {
  const session = http2.connect(`https://${host}:443`);
  session.on("error", () => {});
  return session;
}

function send(session, { token, bundle, payload, jwt, collapse }) {
  return new Promise((resolve) => {
    const body = Buffer.from(JSON.stringify(payload));
    const request = session.request({
      ":method": "POST",
      ":path": `/3/device/${token}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": bundle,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // Several builds landing at once should replace each other on the lock
      // screen rather than stack up.
      "apns-collapse-id": collapse,
      "content-type": "application/json",
      "content-length": body.length,
    });
    let status = 0;
    let reason = "";
    request.on("response", (headers) => { status = headers[":status"] ?? 0; });
    request.on("data", (chunk) => { reason += chunk; });
    request.on("end", () => resolve({ status, reason }));
    request.on("error", (error) => resolve({ status: 0, reason: error.message }));
    request.end(body);
  });
}

/// Deliver to every phone that asked for what turned up. Returns the tokens
/// Apple says are gone, for the caller to forget.
export async function deliver({ devices, key, keyId, teamId, payloadFor, collapse }) {
  const jwt = assertion({ key, keyId, teamId });
  const sessions = new Map();
  const gone = [];
  let delivered = 0;
  try {
    for (const device of devices) {
      const payload = payloadFor(device);
      if (!payload) continue;
      const host = device.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
      if (!sessions.has(host)) sessions.set(host, connect(host));
      const { status, reason } = await send(sessions.get(host), {
        token: device.token, bundle: device.bundle, payload, jwt, collapse,
      });
      if (status === 200) { delivered += 1; continue; }
      // 410 is a phone that no longer wants it; 400 BadDeviceToken is one that
      // never could. Both are worth forgetting rather than retrying forever.
      if (status === 410 || reason.includes("BadDeviceToken") || reason.includes("Unregistered")) {
        gone.push(device.token);
        continue;
      }
      console.log(JSON.stringify({ apnsToken: device.token.slice(0, 8), status, reason }));
    }
  } finally {
    for (const session of sessions.values()) session.close();
  }
  return { delivered, gone };
}

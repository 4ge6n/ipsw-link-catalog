import webpush from "web-push";
import { deliver } from "./apns.mjs";

const worker = "https://ipsw-link-catalog-feed-relay.shigelon.workers.dev";
const publicKey = "BJYIRbL04SrBYIvumqQ-Cj9WeH8PpTvAg63X3cJt-1cCa4ZUG4NoIqn4ItkCOB9TYf9oAVJs2DVNw7CegjLAW2k";
const token = process.env.PUSH_API_TOKEN;
const privateKey = process.env.WEB_PUSH_VAPID_PRIVATE_KEY;

if (!token || !privateKey) throw new Error("Missing push notification secrets.");

const internal = async (path, init = {}) => {
  const response = await fetch(worker + path, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, ...(init.headers || {}) }
  });
  if (!response.ok) throw new Error(`Worker ${path}: HTTP ${response.status}`);
  return response;
};

/// The relay answers unknown paths with its status rather than a 404, so a
/// route that has not been deployed yet comes back 200 and looks like an
/// answer. Say which field was missing, rather than failing later on a value
/// that was never there.
const listFrom = async (path, field) => {
  const body = await (await internal(path)).json();
  if (!Array.isArray(body[field])) {
    throw new Error(`Worker ${path}: no "${field}" in the reply — is the relay deployed? Got: ${JSON.stringify(body).slice(0, 200)}`);
  }
  return body[field];
};

// A test run proves the delivery path without waiting for Apple to ship.
const test = process.env.TEST_PUSH === "1";
const builds = (() => {
  try { return JSON.parse(process.env.NEW_BUILDS || "[]"); } catch { return []; }
})();

const names = { ios: "iOS", ipados: "iPadOS", macos: "macOS", tvos: "tvOS", visionos: "visionOS", audioos: "audioOS" };
const describe = (build) => `${names[build.os] ?? build.os} ${build.version} (${build.build})`;

/// What the whole run is about, for the browsers, which are not told which
/// platform they asked for.
const headline = test
  ? "IPSW Link Catalog test"
  : builds.length === 1 ? `${describe(builds[0])} is out` : "IPSW Link Catalog updated";
const detail = test
  ? "Notifications are working. You will get one like this when new links appear."
  : builds.length
    ? builds.slice(0, 4).map(describe).join(", ") + (builds.length > 4 ? ` and ${builds.length - 4} more` : "")
    : "New Apple IPSW download links are available.";

webpush.setVapidDetails("https://github.com/4ge6n", publicKey, privateKey);
const subscriptions = await listFrom("/internal/subscriptions", "subscriptions");
const payload = JSON.stringify({ title: headline, body: detail, url: "https://4ge6n.github.io/ipsw-link-catalog/" });

let delivered = 0;
for (const subscription of subscriptions) {
  try {
    await webpush.sendNotification(subscription, payload, { TTL: 60 * 60 });
    delivered += 1;
  } catch (error) {
    if (error.statusCode === 404 || error.statusCode === 410) {
      await internal("/internal/subscriptions", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ endpoint: subscription.endpoint }) });
      continue;
    }
    throw error;
  }
}

// The phones, each told only about what it asked to hear about. Without a key
// there are no phones to tell, and the browsers above were served regardless.
let phones = { delivered: 0, gone: [] };
const key = process.env.APNS_KEY;
if (key) {
  const devices = await listFrom("/internal/device-tokens", "devices");
  phones = await deliver({
    devices,
    key,
    keyId: process.env.APNS_KEY_ID,
    teamId: process.env.APNS_TEAM_ID,
    collapse: test ? "test" : (builds[0] ? `${builds[0].os}-${builds[0].build}` : "catalog"),
    payloadFor: (device) => {
      const wanted = test ? builds : builds.filter((build) =>
        (device.platforms.length === 0 || device.platforms.includes(build.os))
        && (device.betas || build.channel === "release"));
      if (!test && wanted.length === 0) return null;
      const title = test
        ? "IPSW Browser test"
        : wanted.length === 1 ? describe(wanted[0]) : "New builds are out";
      const body = test
        ? "Notifications are working. You will get one like this when a build appears."
        : wanted.length === 1
          ? (wanted[0].channel === "release" ? "Released and signed." : "A beta build is available.")
          : wanted.slice(0, 4).map(describe).join(", ");
      return {
        aps: { alert: { title, body }, sound: "default", "interruption-level": "active" },
        builds: wanted.slice(0, 8),
      };
    },
  });
  for (const dead of phones.gone) {
    await internal("/internal/device-tokens", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token: dead }) });
  }
}

console.log(JSON.stringify({
  subscriptions: subscriptions.length, delivered,
  phones: phones.delivered, forgotten: phones.gone.length,
  builds: builds.length,
}));

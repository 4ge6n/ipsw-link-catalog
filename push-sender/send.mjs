import webpush from "web-push";

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

webpush.setVapidDetails("https://github.com/4ge6n", publicKey, privateKey);
const { subscriptions } = await (await internal("/internal/subscriptions")).json();
// A test run proves the delivery path without waiting for Apple to ship.
const test = process.env.TEST_PUSH === "1";
const payload = JSON.stringify({
  title: test ? "IPSW Link Catalog test" : "IPSW Link Catalog updated",
  body: test
    ? "Notifications are working. You will get one like this when new links appear."
    : "New Apple IPSW download links are available.",
  url: "https://4ge6n.github.io/ipsw-link-catalog/"
});

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
console.log(JSON.stringify({ subscriptions: subscriptions.length, delivered }));

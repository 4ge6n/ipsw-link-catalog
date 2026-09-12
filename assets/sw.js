self.addEventListener("push", (event) => {
  const data = event.data ? event.data.json() : {};
  event.waitUntil(self.registration.showNotification(data.title || "IPSW Link Catalog updated", {
    body: data.body || "New IPSW download links are available.",
    icon: "/ipsw-link-catalog/icon.svg",
    badge: "/ipsw-link-catalog/icon.svg",
    data: { url: data.url || "/ipsw-link-catalog/" }
  }));
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});

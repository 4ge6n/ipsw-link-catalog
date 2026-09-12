(() => {
  const button = document.querySelector("#enable-notifications");
  const status = document.querySelector("#push-status");
  const config = self.IPSW_PUSH_CONFIG;
  const installed = matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
  const setStatus = (message) => { if (status) status.textContent = message; };
  const bytes = (value) => Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4)), (char) => char.charCodeAt(0));

  if (!button || !config || !("serviceWorker" in navigator) || !("PushManager" in self) || !("Notification" in self)) {
    if (button) button.hidden = true;
    return;
  }
  if (!installed) setStatus("iPhone/iPadでは、共有メニューから「ホーム画面に追加」したWebアプリで通知を有効にできます。");
  if (Notification.permission === "granted") setStatus("Update notifications are enabled.");

  button.addEventListener("click", async () => {
    if (!installed) {
      setStatus("先にSafariの共有メニューから「ホーム画面に追加」を行い、ホーム画面のアイコンから開いてください。");
      return;
    }
    try {
      const registration = await navigator.serviceWorker.register("/ipsw-link-catalog/sw.js", { scope: "/ipsw-link-catalog/" });
      const permission = await Notification.requestPermission();
      if (permission !== "granted") throw new Error("Notification permission was not granted.");
      const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: bytes(config.publicKey) });
      const response = await fetch(config.endpoint + "/subscriptions", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(subscription) });
      if (!response.ok) throw new Error("Subscription registration failed.");
      setStatus("Update notifications are enabled.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Could not enable notifications.");
    }
  });
})();

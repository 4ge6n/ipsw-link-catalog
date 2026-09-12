(() => {
  const storageKey = "ipsw-download-queue-v1";
  const controls = document.querySelector(".download-queue");
  if (!controls) return;
  const status = controls.querySelector("[data-download-queue-status]");
  const read = () => {
    try { return JSON.parse(sessionStorage.getItem(storageKey) || "[]"); }
    catch { return []; }
  };
  const write = (queue) => sessionStorage.setItem(storageKey, JSON.stringify(queue));
  const describe = (queue) => status.textContent = queue.length ? `${queue.length} file(s) remaining in the download queue.` : "No queued downloads.";
  const openNext = () => {
    const queue = read();
    const next = queue.shift();
    write(queue);
    describe(queue);
    if (!next) return;
    // Safari requires each cross-origin download to follow a user gesture.
    // Opening exactly one Apple CDN URL preserves that rule and avoids pop-up blocking.
    window.open(next.url, "_blank", "noopener");
    status.textContent = `Opened ${next.name}. After saving it, return here and open the next download (${queue.length} remaining).`;
  };
  controls.querySelector("[data-download-queue-start]").addEventListener("click", () => {
    const selected = [...document.querySelectorAll(".download-queue-item:checked")].map((item) => ({ url: item.dataset.url, name: item.dataset.name }));
    if (!selected.length) { status.textContent = "Select at least one Apple download link first."; return; }
    write(selected);
    openNext();
  });
  controls.querySelector("[data-download-queue-next]").addEventListener("click", openNext);
  describe(read());
})();

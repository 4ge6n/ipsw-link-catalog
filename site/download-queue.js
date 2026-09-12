(() => {
  const storageKey = "ipsw-download-queue-v2";
  const sections = [...document.querySelectorAll(".download-queue")];
  if (!sections.length) return;
  const read = () => {
    try { return JSON.parse(localStorage.getItem(storageKey) || "[]"); }
    catch { return []; }
  };
  const write = (queue) => {
    try { localStorage.setItem(storageKey, JSON.stringify(queue)); }
    catch { /* private mode: the queue simply does not survive the page */ }
  };
  const announce = (message) => sections.forEach((section) => {
    section.querySelector("[data-download-queue-status]").textContent = message;
  });
  const describe = (queue) => announce(queue.length
    ? `${queue.length} file(s) queued: ${queue[0].name} is next.`
    : "No queued downloads.");
  const openNext = () => {
    const queue = read();
    const next = queue.shift();
    write(queue);
    if (!next) { describe(queue); return; }
    // Safari requires each cross-origin download to follow a user gesture.
    // Opening exactly one Apple CDN URL preserves that rule and avoids pop-up blocking.
    window.open(next.url, "_blank", "noopener");
    announce(`Opened ${next.name}. After saving it, open the next download (${queue.length} remaining).`);
  };
  sections.forEach((section) => {
    // Each release has its own table, so scope the checkbox buttons to it.
    const table = section.nextElementSibling;
    const items = () => [...table.querySelectorAll(".download-queue-item")];
    const setAll = (checked, message) => {
      items().forEach((item) => { item.checked = checked; });
      announce(message);
    };
    section.querySelector("[data-download-queue-select-all]").addEventListener("click", () => setAll(true, "All files in this table are selected."));
    section.querySelector("[data-download-queue-clear]").addEventListener("click", () => setAll(false, "Selection cleared."));
    section.querySelector("[data-download-queue-add]").addEventListener("click", () => {
      const selected = items().filter((item) => item.checked);
      if (!selected.length) { announce("Select at least one Apple download link first."); return; }
      const queue = read();
      const known = new Set(queue.map((entry) => entry.url));
      let added = 0;
      selected.forEach((item) => {
        if (known.has(item.dataset.url)) return;
        known.add(item.dataset.url);
        queue.push({ url: item.dataset.url, name: item.dataset.name });
        added += 1;
      });
      write(queue);
      setAll(false, `Added ${added} file(s). The queue holds ${queue.length} file(s) and keeps them while you browse other versions or operating systems.`);
    });
    section.querySelector("[data-download-queue-next]").addEventListener("click", openNext);
    section.querySelector("[data-download-queue-reset]").addEventListener("click", () => {
      write([]);
      announce("Queue emptied.");
    });
  });
  describe(read());
  // Another tab may have consumed or extended the queue.
  window.addEventListener("storage", (event) => { if (event.key === storageKey) describe(read()); });
})();

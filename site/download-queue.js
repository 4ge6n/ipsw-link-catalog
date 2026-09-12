(() => {
  const storageKey = "ipsw-download-queue-v2";
  const sections = [...document.querySelectorAll(".download-queue")];
  if (!sections.length) return;
  // A Home Screen web app runs without browser chrome, so window.open is unreliable there.
  const standalone = window.navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches;
  const read = () => {
    try { return JSON.parse(localStorage.getItem(storageKey) || "[]"); }
    catch { return []; }
  };
  const write = (queue) => {
    try { localStorage.setItem(storageKey, JSON.stringify(queue)); }
    catch { /* private mode: the queue simply does not survive the page */ }
    render(queue);
  };
  const announce = (message) => sections.forEach((section) => {
    section.querySelector("[data-download-queue-status]").textContent = message;
  });
  const openDownload = (entry) => {
    // Tapping a real link is the gesture Safari accepts in both tabs and standalone apps.
    const anchor = document.createElement("a");
    anchor.href = entry.url;
    anchor.rel = "noopener";
    if (!standalone) anchor.target = "_blank";
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
  };
  const remove = (url) => {
    const queue = read().filter((entry) => entry.url !== url);
    write(queue);
    announce(`Removed. ${queue.length} file(s) left in the queue.`);
  };
  const openNext = () => {
    const queue = read();
    const next = queue.shift();
    if (!next) { write(queue); announce("No queued downloads."); return; }
    write(queue);
    openDownload(next);
    announce(`Opened ${next.name}. After saving it, open the next download (${queue.length} remaining).`);
  };
  const render = (queue) => sections.forEach((section) => {
    const count = section.querySelector("[data-download-queue-count]");
    const panel = section.querySelector("[data-download-queue-panel]");
    count.textContent = queue.length ? ` (${queue.length})` : "";
    panel.textContent = "";
    if (!queue.length) {
      panel.appendChild(Object.assign(document.createElement("p"), { className: "meta", textContent: "The queue is empty." }));
      return;
    }
    const list = document.createElement("ol");
    queue.forEach((entry) => {
      const item = document.createElement("li");
      const anchor = document.createElement("a");
      anchor.href = entry.url;
      anchor.textContent = entry.name;
      anchor.rel = "noopener";
      if (!standalone) anchor.target = "_blank";
      // Tapping an entry downloads it and takes it out of the queue.
      anchor.addEventListener("click", () => remove(entry.url));
      const drop = document.createElement("button");
      drop.type = "button";
      drop.className = "queue-remove";
      drop.textContent = "Remove";
      drop.addEventListener("click", () => remove(entry.url));
      item.append(anchor, " ", drop);
      list.appendChild(item);
    });
    panel.appendChild(list);
  });
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
    const toggle = section.querySelector("[data-download-queue-show]");
    const panel = section.querySelector("[data-download-queue-panel]");
    toggle.addEventListener("click", () => {
      const open = panel.hidden;
      panel.hidden = !open;
      toggle.setAttribute("aria-expanded", String(open));
    });
  });
  render(read());
  // Another tab, or the Safari copy of this site, may have changed the queue.
  window.addEventListener("storage", (event) => { if (event.key === storageKey) render(read()); });
})();

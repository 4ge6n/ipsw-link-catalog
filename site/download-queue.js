(() => {
  const storageKey = "ipsw-download-queue-v2";
  const sections = [...document.querySelectorAll(".download-queue")];
  if (!sections.length) return;
  // A Home Screen web app runs without browser chrome, so window.open is unreliable there.
  const standalone = window.navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches;
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  // iOS has no Vibration API. A switch-style checkbox toggled inside a user
  // gesture is the one way Safari 17.4+ plays the system haptic; other
  // browsers get the real thing.
  const hapticSwitch = (() => {
    const input = document.createElement("input");
    input.type = "checkbox";
    if (!("switch" in input)) return null;
    input.setAttribute("switch", "");
    input.className = "haptic-switch";
    input.id = "ipsw-haptic-switch";
    input.tabIndex = -1;
    input.setAttribute("aria-hidden", "true");
    const label = document.createElement("label");
    label.className = "haptic-switch";
    label.htmlFor = input.id;
    label.setAttribute("aria-hidden", "true");
    document.body.append(input, label);
    return label;
  })();
  const haptic = (pattern) => {
    if (reduceMotion) return;
    if (hapticSwitch) { hapticSwitch.click(); return; }
    try { navigator.vibrate?.(pattern); } catch { /* unsupported */ }
  };
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
  const remove = (url, item) => {
    haptic(10);
    const drop = () => {
      const queue = read().filter((entry) => entry.url !== url);
      write(queue);
      announce(`Removed. ${queue.length} file(s) left in the queue.`);
    };
    if (reduceMotion || !item) { drop(); return; }
    // Let the row fade out before the list is rebuilt.
    item.classList.add("is-leaving");
    setTimeout(drop, 180);
  };
  const openNext = () => {
    haptic([12, 40, 18]);
    const queue = read();
    const next = queue.shift();
    if (!next) { write(queue); announce("No queued downloads."); return; }
    write(queue);
    openDownload(next);
    announce(`Opened ${next.name}. After saving it, open the next download (${queue.length} remaining).`);
  };
  const render = (queue) => sections.forEach((section) => {
    const count = section.querySelector("[data-download-queue-count]");
    const body = section.querySelector("[data-download-queue-panel-body]");
    count.textContent = queue.length ? ` (${queue.length})` : "";
    body.textContent = "";
    if (!queue.length) {
      body.appendChild(Object.assign(document.createElement("p"), { className: "meta", textContent: "The queue is empty." }));
      return;
    }
    const list = document.createElement("ol");
    list.className = "queue-list";
    queue.forEach((entry) => {
      const item = document.createElement("li");
      const anchor = document.createElement("a");
      anchor.href = entry.url;
      anchor.textContent = entry.name;
      anchor.rel = "noopener";
      if (!standalone) anchor.target = "_blank";
      // Tapping an entry downloads it and takes it out of the queue.
      anchor.addEventListener("click", () => remove(entry.url, item));
      const drop = document.createElement("button");
      drop.type = "button";
      drop.className = "queue-remove";
      drop.textContent = "Remove";
      drop.addEventListener("click", () => remove(entry.url, item));
      item.append(anchor, " ", drop);
      list.appendChild(item);
    });
    body.appendChild(list);
  });
  sections.forEach((section) => {
    // Each release has its own table, so scope the checkbox buttons to it.
    const table = section.nextElementSibling;
    const items = () => [...table.querySelectorAll(".download-queue-item")];
    const setAll = (checked, message) => {
      haptic(8);
      items().forEach((item) => { item.checked = checked; });
      announce(message);
    };
    section.querySelector("[data-download-queue-select-all]").addEventListener("click", () => setAll(true, "All files in this table are selected."));
    section.querySelector("[data-download-queue-clear]").addEventListener("click", () => setAll(false, "Selection cleared."));
    section.querySelector("[data-download-queue-add]").addEventListener("click", () => {
      const selected = items().filter((item) => item.checked);
      if (!selected.length) { haptic([20, 60, 20]); announce("Select at least one Apple download link first."); return; }
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
      haptic([20, 60, 20]);
      write([]);
      announce("Queue emptied.");
    });
    const toggle = section.querySelector("[data-download-queue-show]");
    const panel = section.querySelector("[data-download-queue-panel]");
    toggle.addEventListener("click", () => {
      haptic(8);
      const open = !panel.classList.contains("is-open");
      panel.classList.toggle("is-open", open);
      panel.setAttribute("aria-hidden", String(!open));
      toggle.setAttribute("aria-expanded", String(open));
    });
  });
  render(read());
  // Another tab, or the Safari copy of this site, may have changed the queue.
  window.addEventListener("storage", (event) => { if (event.key === storageKey) render(read()); });
})();

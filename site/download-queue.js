(() => {
  const storageKey = "ipsw-download-queue-v2";
  const sections = [...document.querySelectorAll(".download-queue")];
  if (!sections.length) return;
  // A Home Screen web app runs without browser chrome, so window.open is unreliable there.
  const standalone = window.navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches;
  // iOS confirms every download separately and blocks the ones that follow,
  // so unattended downloading is only offered where the browser allows it.
  const iOS = /iPad|iPhone|iPod/.test(navigator.platform)
    || (navigator.maxTouchPoints > 1 && navigator.platform === "MacIntel")
    || /iPad|iPhone|iPod/.test(navigator.userAgent);
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
  let running = null;
  const batchSize = (section) => {
    const value = section.querySelector("[data-download-queue-batch]").value;
    return value === "all" ? Infinity : Number(value);
  };
  const runBatch = async (section) => {
    if (running) { running.stop = true; return; }
    const state = { stop: false };
    running = state;
    const buttons = sections.map((s) => s.querySelector("[data-download-queue-all]"));
    buttons.forEach((button) => { button.textContent = "Stop"; });
    haptic([12, 40, 18]);
    const limit = batchSize(section);
    let started = 0;
    while (!state.stop && started < limit) {
      const queue = read();
      const next = queue.shift();
      if (!next) break;
      write(queue);
      openDownload(next);
      started += 1;
      announce(`Downloading ${next.name} — ${queue.length} still queued. Keep this page open.`);
      if (!queue.length || started >= limit) break;
      // Browsers throttle bursts of downloads, so leave each one time to start.
      await new Promise((resolve) => setTimeout(resolve, 1500));
    }
    const left = read().length;
    if (state.stop) announce(`Stopped. ${left} file(s) still queued.`);
    else if (!started) announce("No queued downloads.");
    else if (left) announce(`Started ${started} download(s). ${left} left — press Download again once these have finished.`);
    else announce(`Started ${started} download(s). The queue is empty.`);
    running = null;
    refreshLabels();
  };
  const refreshLabels = () => sections.forEach((section) => {
    const button = section.querySelector("[data-download-queue-all]");
    if (running) { button.textContent = "Stop"; return; }
    const limit = batchSize(section);
    const left = read().length;
    const count = Math.min(limit, left || limit);
    button.textContent = left > count ? `Download next ${count}` : "Download all";
  });
  // A picker never reveals the chosen path, so let the user place the script
  // with the system dialog and have the script download beside itself.
  const saveFile = async (name, body, type) => {
    if (window.showSaveFilePicker) {
      try {
        const handle = await window.showSaveFilePicker({ suggestedName: name, types: [type] });
        const writable = await handle.createWritable();
        await writable.write(body);
        await writable.close();
        return handle.name;
      } catch (error) {
        if (error && error.name === "AbortError") return null;
        // Anything else (an unsupported context, a denied prompt) falls back.
      }
    }
    saveText(name, body);
    return name;
  };
  const saveText = (name, body) => {
    const url = URL.createObjectURL(new Blob([body], { type: "text/plain" }));
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = name;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  };
  // curl runs one URL at a time and resumes a partial file, which is what a
  // browser cannot do: it never learns when a cross-origin download finished.
  const destination = (section) => section.querySelector("[data-download-queue-dest]").value.trim();
  const parallel = (section) => section.querySelector("[data-download-queue-jobs]").value;
  const shellQuote = (value) => value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  const script = (queue, dest, jobs) => [
    "#!/bin/bash",
    "# IPSW download queue exported from the IPSW link catalog.",
    "# Usage: bash ipsw-queue.sh [destination] [parallel downloads]",
    `#        defaults: ${dest || "the folder holding this script"}, ${jobs} at a time`,
    "set -u",
    '# Files land next to this script unless another folder is given.',
    'here="$(cd "$(dirname "$0")" && pwd)"',
    dest ? `dest="\${1:-${shellQuote(dest)}}"` : 'dest="${1:-$here}"',
    `jobs="\${2:-${jobs}}"`,
    '# "~" does not expand inside quotes, so do it here.',
    'case "$dest" in "~") dest="$HOME";; "~/"*) dest="$HOME/${dest#\\~/}";; esac',
    'mkdir -p "$dest" || exit 1',
    'cd "$dest" || exit 1',
    "urls=(",
    ...queue.map((entry) => `"${entry.url}"`),
    ")",
    "total=${#urls[@]}",
    'work="$(mktemp -d)"',
    "trap 'rm -rf \"$work\"' EXIT",
    'printf 0 > "$work/count"',
    "",
    "# Parallel jobs would otherwise read the same count and report it twice.",
    "record() {",
    '  while ! mkdir "$work/lock" 2>/dev/null; do sleep 0.05; done',
    '  count=$(($(cat "$work/count") + 1))',
    '  printf "%s" "$count" > "$work/count"',
    '  rmdir "$work/lock"',
    '  printf "%s" "$count"',
    "}",
    "",
    "human() {",
    "  awk -v bytes=\"$1\" 'BEGIN{ if (bytes <= 0) { printf \"unknown size\"; exit }",
    "    split(\"B KiB MiB GiB TiB\", unit, \" \"); i = 1",
    "    while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }",
    "    printf \"%.1f %s\", bytes, unit[i] }'",
    "}",
    "",
    "remote_size() {",
    "  curl -sIL \"$1\" | awk 'tolower($1) == \"content-length:\" { size = $2 } END { printf \"%d\", size + 0 }'",
    "}",
    "",
    "fetch() {",
    '  index="$1"; url="$2"; name="${url##*/}"',
    '  size="$(remote_size "$url")"',
    `  printf '[%s/%s] %s (%s)\\n' "$index" "$total" "$name" "$(human "$size")"`,
    '  started=$SECONDS',
    "  # -C - resumes a partial file and leaves a complete one alone.",
    '  if [ "$jobs" -le 1 ]; then',
    '    curl -fL -OC - --retry 3 --retry-delay 5 --progress-bar "$url" || { echo "$name" >> "$work/failed"; return 1; }',
    "  else",
    '    curl -fL -OC - --retry 3 --retry-delay 5 -sS "$url" || { echo "$name" >> "$work/failed"; return 1; }',
    "  fi",
    '  done_count="$(record)"',
    `  printf '      finished %s in %ss (%s of %s complete)\\n' "$name" "$((SECONDS - started))" "$done_count" "$total"`,
    "}",
    "",
    'printf \'Downloading %s file(s) into %s, %s at a time.\\n\' "$total" "$dest" "$jobs"',
    "index=0",
    'for url in "${urls[@]}"; do',
    "  index=$((index + 1))",
    '  if [ "$jobs" -le 1 ]; then',
    '    fetch "$index" "$url"',
    "  else",
    '    fetch "$index" "$url" &',
    "    # Keep at most $jobs transfers running at once.",
    '    while [ "$(jobs -pr | wc -l | tr -d " ")" -ge "$jobs" ]; do sleep 0.5; done',
    "  fi",
    "done",
    "wait",
    "",
    'completed="$(cat "$work/count")"',
    'if [ -f "$work/failed" ]; then',
    `  printf 'Finished %s of %s. Failed:\\n' "$completed" "$total" >&2`,
    '  sed "s/^/  /" "$work/failed" >&2',
    `  printf 'Run this script again to retry; finished files are left alone.\\n' >&2`,
    "  exit 1",
    "fi",
    `printf 'Done: %s file(s) in %s\\n' "$completed" "$dest"`,
  ].join("\n") + "\n";
  const runCommand = () => "bash ipsw-queue.sh";
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
    if (!iOS) section.querySelector("[data-download-queue-all]").textContent = running ? "Stop" : (queue.length > batchSize(section) ? `Download next ${batchSize(section)}` : "Download all");
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
    // A release page scopes its buttons to its own table; a page that lists
    // several releases carries one control set for every table on it.
    const wholePage = section.dataset.downloadQueueScope === "page";
    const root = wholePage ? document : section.nextElementSibling;
    const items = () => [...root.querySelectorAll(".download-queue-item")];
    const setAll = (checked, message) => {
      haptic(8);
      items().forEach((item) => { item.checked = checked; });
      announce(message);
    };
    section.querySelector("[data-download-queue-select-all]").addEventListener("click", () => setAll(true, `All ${items().length} file(s) ${wholePage ? "on this page" : "in this table"} are selected.`));
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
    const all = section.querySelector("[data-download-queue-all]");
    const batch = section.querySelector("[data-download-queue-batch]");
    if (iOS) {
      // One tap per file is the only thing iOS reliably allows.
      all.hidden = true;
      (batch.closest("label") || batch).hidden = true;
    } else {
      all.addEventListener("click", () => runBatch(section));
      batch.addEventListener("change", () => {
        sections.forEach((other) => { other.querySelector("[data-download-queue-batch]").value = batch.value; });
        refreshLabels();
      });
    }
    const dest = section.querySelector("[data-download-queue-dest]");
    dest.addEventListener("input", () => sections.forEach((other) => {
      other.querySelector("[data-download-queue-dest]").value = dest.value;
    }));
    const jobs = section.querySelector("[data-download-queue-jobs]");
    jobs.addEventListener("change", () => sections.forEach((other) => {
      other.querySelector("[data-download-queue-jobs]").value = jobs.value;
    }));
    section.querySelector("[data-download-queue-export]").addEventListener("click", async () => {
      const queue = read();
      if (!queue.length) { announce("The queue is empty."); return; }
      haptic(10);
      const dest = destination(section);
      const saved = await saveFile("ipsw-queue.sh", script(queue, dest, parallel(section)), { description: "Shell script", accept: { "text/x-shellscript": [".sh"] } });
      if (!saved) { announce("Nothing saved."); return; }
      announce(`Saved ${saved}: ${queue.length} file(s) into ${dest || "the folder you chose"}, ${parallel(section)} at a time. Run it with: bash ${saved}`);
    });
    section.querySelector("[data-download-queue-list]").addEventListener("click", async () => {
      const queue = read();
      if (!queue.length) { announce("The queue is empty."); return; }
      haptic(10);
      const saved = await saveFile("ipsw-queue.txt", queue.map((entry) => entry.url).join("\n") + "\n", { description: "URL list", accept: { "text/plain": [".txt"] } });
      announce(saved ? `Saved ${saved} with ${queue.length} URL(s), for aria2c or wget.` : "Nothing saved.");
    });
    section.querySelector("[data-download-queue-copy]").addEventListener("click", async () => {
      haptic(10);
      try {
        await navigator.clipboard.writeText(runCommand());
        announce("Command copied. Save the script first, then run it.");
      } catch {
        announce(`Copy this command: ${runCommand()}`);
      }
    });
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
  refreshLabels();
  // Another tab, or the Safari copy of this site, may have changed the queue.
  window.addEventListener("storage", (event) => { if (event.key === storageKey) render(read()); });
})();

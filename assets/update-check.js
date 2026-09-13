(() => {
  const meta = document.querySelector("meta[name='catalog-build']");
  if (!meta) return;
  const build = meta.content;
  const base = meta.dataset.base || "";
  // The bar stays out of the way until there is actually something to say.
  const bar = document.createElement("aside");
  bar.className = "update-bar";
  const text = document.createElement("span");
  const action = document.createElement("button");
  action.type = "button";
  action.textContent = "Reload";
  // GitHub Pages serves HTML with max-age=600, so ask for a fresh copy.
  action.addEventListener("click", () => location.reload());
  bar.append(text, action);
  const stale = (published) => {
    text.textContent = published ? `A newer catalog is available (${published}).` : "A newer catalog is available.";
    bar.classList.add("is-stale");
  };
  let checking = false;
  const check = async () => {
    if (checking || bar.classList.contains("is-stale")) return;
    checking = true;
    try {
      const response = await fetch(`${base}version.json`, { cache: "no-store" });
      if (!response.ok) throw new Error(response.status);
      const latest = await response.json();
      if (latest.build && latest.build !== build) stale(latest.generated_at_tokyo || latest.generated_at);
    } catch { /* offline: try again on the next check */ }
    finally { checking = false; }
  };
  document.body.appendChild(bar);
  check();
  // A Home Screen app is resumed rather than reloaded, so re-check on return.
  document.addEventListener("visibilitychange", () => { if (!document.hidden) check(); });
  setInterval(() => { if (!document.hidden) check(); }, 5 * 60 * 1000);
})();

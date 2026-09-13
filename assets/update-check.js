(() => {
  const meta = document.querySelector("meta[name='catalog-build']");
  if (!meta) return;
  const build = meta.content;
  const base = meta.dataset.base || "";
  const bar = document.createElement("aside");
  bar.className = "update-bar";
  const text = document.createElement("span");
  const action = document.createElement("button");
  action.type = "button";
  action.textContent = "Check for updates";
  bar.append(text, " ", action);
  const idle = () => {
    bar.classList.remove("is-stale");
    text.textContent = `Catalog build ${build}.`;
    action.textContent = "Check for updates";
    action.onclick = () => check(true);
  };
  const stale = (published) => {
    bar.classList.add("is-stale");
    text.textContent = `A newer catalog is available (${published}).`;
    action.textContent = "Reload";
    // GitHub Pages serves HTML with max-age=600, so ask for a fresh copy.
    action.onclick = () => location.reload();
  };
  let checking = false;
  const check = async (manual) => {
    if (checking) return;
    checking = true;
    if (manual) text.textContent = "Checking…";
    try {
      const response = await fetch(`${base}version.json`, { cache: "no-store" });
      if (!response.ok) throw new Error(response.status);
      const latest = await response.json();
      if (latest.build && latest.build !== build) stale(latest.generated_at_tokyo || latest.generated_at);
      else if (manual) { idle(); text.textContent = `Up to date (build ${build}).`; }
    } catch {
      if (manual) { idle(); text.textContent = "Could not reach the catalog. Try again later."; }
    } finally {
      checking = false;
    }
  };
  idle();
  document.body.appendChild(bar);
  check(false);
  // A Home Screen app is resumed rather than reloaded, so re-check on return.
  document.addEventListener("visibilitychange", () => { if (!document.hidden) check(false); });
  setInterval(() => { if (!document.hidden) check(false); }, 5 * 60 * 1000);
})();

(() => {
  const stamps = [...document.querySelectorAll("time[data-local-time]")];
  if (!stamps.length) return;
  // The page is generated once in Tokyo time; show it where the reader is.
  const clock = new Intl.DateTimeFormat(undefined, {
    year: "numeric", month: "short", day: "numeric",
    hour: "2-digit", minute: "2-digit", timeZoneName: "short", hour12: false
  });
  const units = [["year", 31557600], ["month", 2629800], ["day", 86400], ["hour", 3600], ["minute", 60]];
  const relative = (date) => {
    const words = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
    const seconds = (date.getTime() - Date.now()) / 1000;
    for (const [unit, size] of units) {
      if (Math.abs(seconds) >= size) return words.format(Math.round(seconds / size), unit);
    }
    return words.format(Math.round(seconds), "second");
  };
  stamps.forEach((stamp) => {
    const date = new Date(stamp.dateTime);
    if (Number.isNaN(date.getTime())) return;
    stamp.textContent = clock.format(date);
    stamp.title = stamp.dateTime;
    const ago = document.createElement("span");
    ago.className = "when-ago";
    ago.textContent = relative(date);
    stamp.after(" ", ago);
  });
})();

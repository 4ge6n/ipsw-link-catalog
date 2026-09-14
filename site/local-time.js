(() => {
  const stamps = [...document.querySelectorAll("time[data-local-time]")];
  if (!stamps.length) return;
  // The catalog is written in English, so the date reads in English. The zone
  // abbreviation comes from the reader's own locale, where "JST" beats "GMT+9".
  const day = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" });
  const time = new Intl.DateTimeFormat("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
  const zone = new Intl.DateTimeFormat(undefined, { hour: "numeric", timeZoneName: "short" });
  const words = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
  const units = [["year", 31557600], ["month", 2629800], ["day", 86400], ["hour", 3600], ["minute", 60]];
  const zoneName = (date) => {
    const part = zone.formatToParts(date).find((piece) => piece.type === "timeZoneName");
    return part ? part.value : "";
  };
  const relative = (date) => {
    const seconds = (date.getTime() - Date.now()) / 1000;
    for (const [unit, size] of units) {
      if (Math.abs(seconds) >= size) return words.format(Math.round(seconds / size), unit);
    }
    return words.format(Math.round(seconds), "second");
  };
  stamps.forEach((stamp) => {
    const date = new Date(stamp.dateTime);
    if (Number.isNaN(date.getTime())) return;
    stamp.textContent = `${day.format(date)} ${time.format(date)} ${zoneName(date)}`.trim();
    stamp.title = stamp.dateTime;
    // A reader already on UTC would otherwise see the same time twice.
    const utc = stamp.nextElementSibling;
    const onUTC = utc && utc.matches("[data-utc-time]") && /\b(UTC|GMT\+0{1,2}(:00)?)$/.test(stamp.textContent);
    if (onUTC) utc.hidden = true;
    const ago = document.createElement("span");
    ago.className = "when-ago";
    ago.textContent = relative(date);
    // Local time, then the fixed UTC stamp, then how long ago it was.
    (utc && utc.matches("[data-utc-time]") && !onUTC ? utc : stamp).after(ago);
  });
})();

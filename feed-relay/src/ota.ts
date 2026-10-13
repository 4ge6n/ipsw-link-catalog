/// Apple's software update service, asked the way a device enrolled in the
/// developer beta asks it. It answers the moment a beta is published, an hour
/// or more before Apple's own release notes feed and well before any public
/// index has the restore images. It gives no IPSW links; those still come
/// from the catalog later. What it gives is that a build exists.

export interface OtaBuild {
  os: string;
  channel: "beta" | "release";
  version: string;
  build: string;
  /// "27.2 beta 4", from Apple's documentation id, when it can be read.
  label: string;
}

/// One device per platform is enough: a beta ships to every device of its
/// platform at once. The audience ids are Apple's developer beta audiences,
/// one per major version, so a new major needs a new line here.
const PROBES: { os: string; audience: string; assetType: string; product: string; board: string; releaseType?: string }[] = [
  { os: "ios", audience: "a5f921db-50af-448c-8f7e-3f093ca2c954", assetType: "com.apple.MobileAsset.SoftwareUpdate", product: "iPhone17,1", board: "D93AP", releaseType: "Beta" },
  { os: "ipados", audience: "a5f921db-50af-448c-8f7e-3f093ca2c954", assetType: "com.apple.MobileAsset.SoftwareUpdate", product: "iPad16,3", board: "J717AP", releaseType: "Beta" },
  { os: "macos", audience: "621ba5ab-54b6-4a71-891a-425ac0ce4551", assetType: "com.apple.MobileAsset.MacSoftwareUpdate", product: "Mac16,1", board: "J604AP" },
  { os: "tvos", audience: "6ca2978e-e976-48b5-9b85-cba646d5dea8", assetType: "com.apple.MobileAsset.SoftwareUpdate", product: "AppleTV14,1", board: "J255AP", releaseType: "Beta" },
  { os: "visionos", audience: "3796f01d-bf07-45c2-8df6-ad7300055ed9", assetType: "com.apple.MobileAsset.SoftwareUpdate", product: "RealityDevice14,1", board: "N301AP", releaseType: "Beta" },
];

/// "iOS272Beta4" → "27.2 beta 4", "macOS272RC" → "27.2 RC".
function labelFrom(documentation: string, version: string): string {
  const match = /(\d+)(Beta|RC)(\d*)$/i.exec(documentation ?? "");
  if (!match) return version;
  return match[2].toUpperCase() === "RC"
    ? `${version} RC${match[3] ? ` ${match[3]}` : ""}`
    : `${version} beta ${match[3] || 1}`;
}

async function probe(p: (typeof PROBES)[number]): Promise<OtaBuild[]> {
  const body: Record<string, unknown> = {
    ClientVersion: 2, AssetAudience: p.audience, AssetType: p.assetType,
    ProductType: p.product, HWModelStr: p.board,
    // "0" asks for everything the audience offers, rather than what one
    // particular installed build would be offered.
    BuildVersion: "0", ProductVersion: "0",
    CertIssuanceDay: "2023-12-10", CompatibilityVersion: 20,
  };
  if (p.releaseType) body.ReleaseType = p.releaseType;
  const response = await fetch("https://gdmf.apple.com/v2/assets", {
    method: "POST",
    headers: { "Content-Type": "application/json", "User-Agent": "ipsw-link-catalog-feed-relay/1.0" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`gdmf ${p.os}: HTTP ${response.status}`);
  // The answer is a signed token; the claims in the middle are the answer.
  const middle = (await response.text()).split(".")[1] ?? "";
  const json = atob(middle.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (middle.length % 4)) % 4));
  const parsed = JSON.parse(new TextDecoder().decode(Uint8Array.from(json, (c) => c.charCodeAt(0)))) as {
    Assets?: { OSVersion?: string; Build?: string; SUDocumentationID?: string }[];
  };
  const found = new Map<string, OtaBuild>();
  for (const asset of parsed.Assets ?? []) {
    if (!asset.Build || !asset.OSVersion) continue;
    // iOS reports "9.9.27.2" to devices that may not yet understand 27.2.
    const version = asset.OSVersion.replace(/^9\.9\./, "");
    const documentation = asset.SUDocumentationID ?? "";
    const prerelease = /Beta|RC/i.test(documentation) || /[a-z]$/.test(asset.Build);
    found.set(asset.Build, {
      os: p.os, channel: prerelease ? "beta" : "release", version, build: asset.Build,
      label: labelFrom(documentation, version),
    });
  }
  return [...found.values()];
}

/// Every build the beta audiences currently offer. A platform that fails to
/// answer is left out rather than failing the rest, and the caller is told
/// which, so a silent platform is not mistaken for one with nothing new.
export async function otaBuilds(): Promise<{ builds: OtaBuild[]; failed: string[] }> {
  const results = await Promise.allSettled(PROBES.map(probe));
  const builds: OtaBuild[] = [];
  const failed: string[] = [];
  results.forEach((result, index) => {
    if (result.status === "fulfilled") builds.push(...result.value);
    else failed.push(PROBES[index].os);
  });
  return { builds, failed };
}

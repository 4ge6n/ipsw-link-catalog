# IPSW Link Catalog

Stable JSON indexes of Apple restore-image URLs. IPSW files are never stored in this repository.

<!-- AUTO-GENERATED:START -->
## Catalog status

Last successful update (UTC): `2026-09-22T12:07:30Z`
Last successful update (Asia/Tokyo): `2026-09-22T21:07:30+09:00`

### Endpoints

#### iOS

- `release`: [latest.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/ios/release/latest.json) · [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/ios/release/all.json) (52 IPSW records)
- `beta`: [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/ios/beta/all.json) (8557 IPSW records; no beta latest endpoint)

#### iPadOS

- `release`: [latest.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/ipados/release/latest.json) · [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/ipados/release/all.json) (29 IPSW records)
- `beta`: [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/ipados/beta/all.json) (4905 IPSW records; no beta latest endpoint)

#### tvOS

- `release`: [latest.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/tvos/release/latest.json) · [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/tvos/release/all.json) (3 IPSW records)
- `beta`: [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/tvos/beta/all.json) (256 IPSW records; no beta latest endpoint)

#### visionOS

- `release`: [latest.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/visionos/release/latest.json) · [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/visionos/release/all.json) (2 IPSW records)
- `beta`: [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/visionos/beta/all.json) (170 IPSW records; no beta latest endpoint)

#### audioOS

- `release`: [latest.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/audioos/release/latest.json) · [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/audioos/release/all.json) (2 IPSW records)
- `beta`: [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/audioos/beta/all.json) (0 IPSW records; no beta latest endpoint)

#### macOS

- `release`: [latest.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/macos/release/latest.json) · [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/macos/release/all.json) (1 IPSW records)
- `beta`: [all.json](https://raw.githubusercontent.com/4ge6n/ipsw-link-catalog/main/api/macos/beta/all.json) (275 IPSW records; no beta latest endpoint)

### Refresh

Public firmware sources are polled every five minutes (GitHub Actions scheduling is best-effort). An authenticated external feed relay can request an immediate refresh with the `firmware_release` repository-dispatch event; Apple does not provide this repository a direct IPSW-release webhook.

### Record fields

Use `firmwares[].id` to identify a firmware, `devices` to match hardware, and `signed` to determine current restore availability. URLs are restricted to Apple CDN HTTPS IPSWs.

Data is assembled from public firmware metadata. It is not affiliated with Apple; verify compatibility before restoring.
<!-- AUTO-GENERATED:END -->

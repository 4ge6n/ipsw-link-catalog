# The apps

Two apps, one project. `app/IPSW.xcodeproj` is generated from `project.yml`:

```bash
brew install xcodegen          # once
cd app && xcodegen generate
open IPSW.xcodeproj
```

| Scheme | Target | What it is |
|---|---|---|
| IPSW Sync (Mac) | `IPSWSync` | Keeps folders on a drive in step, and links Finder's restore folder at them. |
| IPSW Browser (iPhone and iPad) | `IPSWBrowser` | Reads the same catalog and saves an image into the Files app. |

They are two targets rather than two projects because they are mostly the same
app: the catalog, the transfer engine, the checksum record and the wording are
one set of files, compiled into each.

The Mac app is also built by `IPSWSync/build-app.sh` with SwiftPM — that is what
the release workflow runs, and what produces the zip the updater fetches. Same
sources either way; the project is for working in Xcode.

The generated project, the generated Info.plists and the drawn icons are not
checked in.

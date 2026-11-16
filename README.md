# Chausima Mail

Email for chausima.com, self-hosted on our own server with [Stalwart](https://stalw.art).
People sign in at **https://mail.chausima.com**.

| Folder | What it is | Licence |
|---|---|---|
| `web/` | The Chausima Mail web page: sign-in, inbox, reading and writing mail. Talks to Stalwart over JMAP. Installable as an app. | Apache-2.0 |
| `apps/android/` | Android app (a window onto mail.chausima.com) | Apache-2.0 |
| `apps/desktop/` | Linux and Mac app (Electron) | Apache-2.0 |
| `admin/` | Stalwart's admin WebUI, rebranded as Chausima Mail Admin | **AGPL-3.0-only** |
| `server/` | Script that puts `web/` live on the server | Apache-2.0 |

## The admin (AGPL)

`admin/` is a modified version of [stalwartlabs/webui](https://github.com/stalwartlabs/webui),
licensed under the GNU Affero General Public License v3.0 only (`admin/LICENSE-AGPL-3.0.txt`).
Our only changes are branding: name, logo, page title and sign-in name.

- Upstream commit: `6b8ad61b57fd7450bef1e061c7186d8c52c13346`
- Our changes: `admin/chausima-branding.patch`
- Built bundle: `admin/webui-chausima.zip`

To rebuild: clone upstream at that commit, `git am admin/chausima-branding.patch`, then `npm ci && npm run build` and zip `dist/`.

## Putting the web page live

On the server:

```
curl -sL https://codeload.github.com/silocell/chausima-mail/tar.gz/main | tar xz && bash chausima-mail-main/server/deploy.sh
```

## Building the apps

- Android: `cd apps/android && gradle assembleRelease` with `CM_KEYSTORE` and `CM_KS_PASS` set. The signing key is **not** in this repository; keep it private, because every update must be signed with the same key.
- Linux and Mac: `cd apps/desktop && npm i && npx electron-builder --linux AppImage` (or `--mac zip`).

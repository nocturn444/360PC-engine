# Room Editor (Android)

Native Android shell for the room editor web UI in `tools/room_editor_web/`. It shows that UI
full screen in a WebView and gives it what a browser cannot: local project files, the phone's
share sheet and file picker, and direct upload of a `.lvl` as a pull request to this repository.

The app is a plain Gradle project (Java, no Kotlin). The only dependency is
`androidx.webkit:webkit`, used for `WebViewAssetLoader`. The app is built from GitHub Actions;
the workflow is part of the repository, not of this folder. No Gradle wrapper jar is committed.

- `applicationId`: `dev.pc360.roomeditor`
- `minSdk` 24, `compileSdk` / `targetSdk` 35
- Android Gradle Plugin 8.7.x (needs Gradle 8.9 or newer and JDK 17)

## Build

At build time the `prepareWebAssets` Gradle task copies `tools/room_editor_web/` into the app's
generated assets. Nothing from the web UI is duplicated here. If that folder has no
`index.html`, the task copies the fallback page in
`app/src/main/assets-fallback/index.html`, so the build still works before the UI issue is
merged.

The app loads the UI from
`https://appassets.androidplatform.net/assets/index.html` through `WebViewAssetLoader`, never
from `file://`. Remote navigation is blocked; the only network access is the bridge's own
`HttpsURLConnection` calls to the GitHub API.

Signing: `release` and `debug` both use `android/room_editor/debug.keystore` when it exists
(store password `android`, alias `androiddebugkey`, key password `android`), so an update
installs over the previous build and keeps its data. Keep that file unchanged across builds. If
it is missing, the build falls back to Android's default debug signing.

## Bridge API

`window.Android` is the `Bridge` class. Every method takes and returns strings. Async methods
take a `callbackId` and later call, on the UI thread:

```js
window.onAndroidResult(callbackId, ok, resultString)
```

File and network work runs on a background thread.

### Local projects

Projects are HTML text files in the app's private `filesDir/projects/` and survive updates.
Names must match `[A-Za-z0-9_.-]+\.lvl`.

| Method | Result |
|---|---|
| `listProjects(callbackId)` | JSON array of `{ name, bytes, modified }` |
| `readProject(name, callbackId)` | the file text |
| `writeProject(name, text, callbackId)` | writes atomically: `<name>.tmp`, previous file kept as `<name>.bak`, then renamed |
| `deleteProject(name, callbackId)` | deletes the project |

### Files on the phone

These use the Storage Access Framework, so no storage permission is needed.

| Method | Result |
|---|---|
| `exportFile(suggestedName, text, callbackId)` | `ACTION_CREATE_DOCUMENT`; result is the chosen file's display name |
| `importFile(callbackId)` | `ACTION_OPEN_DOCUMENT`; result is JSON `{ name, text }` |
| `shareText(fileName, text)` | writes `cacheDir/share/<fileName>` and opens the share sheet (FileProvider, `text/plain`) |

### GitHub

Config is stored in private `SharedPreferences`. The token is never returned to JavaScript, never
logged and never put in an error message.

| Method | Result |
|---|---|
| `setGitHubConfig(owner, repo, token)` | stores the values |
| `getGitHubConfig()` | synchronous JSON `{ owner, repo, hasToken }` |
| `clearGitHubToken()` | removes the token |
| `githubList(dirPath, ref, callbackId)` | JSON array of `{ name, path, sha, size }` for `.lvl` files |
| `githubRead(path, ref, callbackId)` | JSON `{ path, sha, text }` (blobs API for files over 1 MB) |
| `githubUpload(filesJson, title, body, callbackId)` | JSON `{ branch, prUrl, prNumber }` |

`githubUpload` takes `filesJson` = JSON array of `{ path, text }`. It reads the head of `main`,
creates `rooms/<yyyyMMdd-HHmmss>` from it, commits each file there (with the existing `sha` when
the file already exists) and opens a pull request to `main`. It never writes to `main` or to an
existing branch. HTTP errors return the status and GitHub's `message`; timeouts are 30 seconds.

### Page hooks

- `window.onAndroidResult(callbackId, ok, resultString)`: async result.
- `window.onAndroidBack()`: called by the Android back button. Return `true` when the page
  handled it. Anything else asks "Exit Room Editor?" and closes the app on confirmation.

## GitHub token

Create a **fine-grained personal access token** on github.com: Settings > Developer settings >
Personal access tokens > Fine-grained tokens. Give it:

- access to only the `nocturn444/360PC-engine` repository;
- **Contents: Read and write**;
- **Pull requests: Read and write**;
- an expiry date.

Paste the token only in the app's own settings screen. Never send it in a chat, issue, commit or
screenshot.

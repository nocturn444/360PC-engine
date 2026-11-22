package dev.pc360.roomeditor;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import androidx.core.content.FileProvider;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

public class Bridge {

    private static final int REQUEST_EXPORT = 1001;
    private static final int REQUEST_IMPORT = 1002;

    private static final String PREFS = "room_editor";
    private static final String KEY_OWNER = "github_owner";
    private static final String KEY_REPO = "github_repo";
    private static final String KEY_TOKEN = "github_token";

    private static final Pattern PROJECT_NAME = Pattern.compile("[A-Za-z0-9_.-]+\\.lvl");

    private final Activity activity;
    private final WebView webView;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();

    private String pendingExportCallback;
    private String pendingExportText;
    private String pendingImportCallback;

    public Bridge(Activity activity, WebView webView) {
        this.activity = activity;
        this.webView = webView;
    }

    // Local projects

    @JavascriptInterface
    public void listProjects(String callbackId) {
        worker.execute(() -> {
            try {
                File[] files = projectsDir().listFiles();
                JSONArray result = new JSONArray();
                if (files != null) {
                    Arrays.sort(files, (a, b) -> a.getName().compareTo(b.getName()));
                    for (File file : files) {
                        if (!file.isFile() || !file.getName().endsWith(".lvl")) {
                            continue;
                        }
                        JSONObject item = new JSONObject();
                        item.put("name", file.getName());
                        item.put("bytes", file.length());
                        item.put("modified", file.lastModified());
                        result.put(item);
                    }
                }
                sendResult(callbackId, true, result.toString());
            } catch (Exception e) {
                sendError(callbackId, e);
            }
        });
    }

    @JavascriptInterface
    public void readProject(String name, String callbackId) {
        worker.execute(() -> {
            try {
                File file = projectFile(name);
                if (!file.isFile()) {
                    throw new IOException("Project not found");
                }
                sendResult(callbackId, true, readText(file));
            } catch (Exception e) {
                sendError(callbackId, e);
            }
        });
    }

    @JavascriptInterface
    public void writeProject(String name, String text, String callbackId) {
        worker.execute(() -> {
            try {
                writeAtomic(projectFile(name), text == null ? "" : text);
                sendResult(callbackId, true, name);
            } catch (Exception e) {
                sendError(callbackId, e);
            }
        });
    }

    @JavascriptInterface
    public void deleteProject(String name, String callbackId) {
        worker.execute(() -> {
            try {
                File file = projectFile(name);
                deleteFile(file);
                deleteFile(new File(file.getParentFile(), file.getName() + ".tmp"));
                deleteFile(new File(file.getParentFile(), file.getName() + ".bak"));
                sendResult(callbackId, true, name);
            } catch (Exception e) {
                sendError(callbackId, e);
            }
        });
    }

    // Files on the phone (Storage Access Framework)

    @JavascriptInterface
    public void exportFile(String suggestedName, String text, String callbackId) {
        activity.runOnUiThread(() -> {
            pendingExportCallback = callbackId;
            pendingExportText = text == null ? "" : text;
            Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("text/plain");
            intent.putExtra(Intent.EXTRA_TITLE,
                    suggestedName == null || suggestedName.isEmpty() ? "room.lvl" : suggestedName);
            try {
                activity.startActivityForResult(intent, REQUEST_EXPORT);
            } catch (Exception e) {
                pendingExportCallback = null;
                pendingExportText = null;
                sendResult(callbackId, false, "Cannot open file picker");
            }
        });
    }

    @JavascriptInterface
    public void importFile(String callbackId) {
        activity.runOnUiThread(() -> {
            pendingImportCallback = callbackId;
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("*/*");
            try {
                activity.startActivityForResult(intent, REQUEST_IMPORT);
            } catch (Exception e) {
                pendingImportCallback = null;
                sendResult(callbackId, false, "Cannot open file picker");
            }
        });
    }

    public void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQUEST_EXPORT) {
            final String callbackId = pendingExportCallback;
            final String text = pendingExportText;
            pendingExportCallback = null;
            pendingExportText = null;
            if (callbackId == null) {
                return;
            }
            if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
                sendResult(callbackId, false, "Cancelled");
                return;
            }
            final Uri uri = data.getData();
            worker.execute(() -> {
                try {
                    OutputStream out = activity.getContentResolver().openOutputStream(uri, "wt");
                    if (out == null) {
                        throw new IOException("Cannot open file");
                    }
                    try {
                        out.write(text.getBytes(StandardCharsets.UTF_8));
                    } finally {
                        out.close();
                    }
                    sendResult(callbackId, true, displayName(uri, "room.lvl"));
                } catch (Exception e) {
                    sendError(callbackId, e);
                }
            });
        } else if (requestCode == REQUEST_IMPORT) {
            final String callbackId = pendingImportCallback;
            pendingImportCallback = null;
            if (callbackId == null) {
                return;
            }
            if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
                sendResult(callbackId, false, "Cancelled");
                return;
            }
            final Uri uri = data.getData();
            worker.execute(() -> {
                try {
                    InputStream in = activity.getContentResolver().openInputStream(uri);
                    if (in == null) {
                        throw new IOException("Cannot open file");
                    }
                    String text;
                    try {
                        text = readText(in);
                    } finally {
                        in.close();
                    }
                    JSONObject result = new JSONObject();
                    result.put("name", displayName(uri, "room.lvl"));
                    result.put("text", text);
                    sendResult(callbackId, true, result.toString());
                } catch (Exception e) {
                    sendError(callbackId, e);
                }
            });
        }
    }

    @JavascriptInterface
    public void shareText(String fileName, String text) {
        worker.execute(() -> {
            try {
                File dir = new File(activity.getCacheDir(), "share");
                if (!dir.isDirectory() && !dir.mkdirs()) {
                    throw new IOException("Cannot create share folder");
                }
                String safeName = new File(
                        fileName == null || fileName.isEmpty() ? "room.lvl" : fileName).getName();
                File file = new File(dir, safeName);
                writeText(file, text == null ? "" : text);

                Uri uri = FileProvider.getUriForFile(
                        activity, activity.getPackageName() + ".fileprovider", file);
                Intent send = new Intent(Intent.ACTION_SEND);
                send.setType("text/plain");
                send.putExtra(Intent.EXTRA_STREAM, uri);
                send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                activity.runOnUiThread(
                        () -> activity.startActivity(Intent.createChooser(send, "Share room")));
            } catch (Exception ignored) {
                // shareText has no callback; nothing else to report to the page
            }
        });
    }

    // GitHub

    @JavascriptInterface
    public void setGitHubConfig(String owner, String repo, String token) {
        prefs().edit()
                .putString(KEY_OWNER, owner == null ? "" : owner.trim())
                .putString(KEY_REPO, repo == null ? "" : repo.trim())
                .putString(KEY_TOKEN, token == null ? "" : token.trim())
                .apply();
    }

    @JavascriptInterface
    public String getGitHubConfig() {
        JSONObject config = new JSONObject();
        try {
            config.put("owner", prefs().getString(KEY_OWNER, ""));
            config.put("repo", prefs().getString(KEY_REPO, ""));
            config.put("hasToken", !token().isEmpty());
        } catch (JSONException ignored) {
            return "{\"owner\":\"\",\"repo\":\"\",\"hasToken\":false}";
        }
        return config.toString();
    }

    @JavascriptInterface
    public void clearGitHubToken() {
        prefs().edit().remove(KEY_TOKEN).apply();
    }

    @JavascriptInterface
    public void githubList(String dirPath, String ref, String callbackId) {
        worker.execute(() -> {
            try {
                sendResult(callbackId, true,
                        new GitHub().list(owner(), repo(), token(), dirPath, ref));
            } catch (Exception e) {
                sendError(callbackId, e);
            }
        });
    }

    @JavascriptInterface
    public void githubRead(String path, String ref, String callbackId) {
        worker.execute(() -> {
            try {
                sendResult(callbackId, true,
                        new GitHub().read(owner(), repo(), token(), path, ref));
            } catch (Exception e) {
                sendError(callbackId, e);
            }
        });
    }

    @JavascriptInterface
    public void githubUpload(String filesJson, String title, String body, String callbackId) {
        worker.execute(() -> {
            try {
                sendResult(callbackId, true,
                        new GitHub().upload(owner(), repo(), token(), filesJson, title, body));
            } catch (Exception e) {
                sendError(callbackId, e);
            }
        });
    }

    // Helpers

    private void sendResult(String callbackId, boolean ok, String result) {
        String script = "window.onAndroidResult && window.onAndroidResult("
                + JSONObject.quote(callbackId == null ? "" : callbackId)
                + "," + (ok ? "true" : "false")
                + "," + JSONObject.quote(result == null ? "" : result) + ")";
        activity.runOnUiThread(() -> {
            if (webView != null) {
                webView.evaluateJavascript(script, null);
            }
        });
    }

    private void sendError(String callbackId, Exception e) {
        String message;
        if (e instanceof GitHub.ApiException) {
            message = e.getMessage();
        } else if (e instanceof SocketTimeoutException) {
            message = "Network timeout";
        } else if (e instanceof IOException) {
            String text = e.getMessage();
            message = text == null || text.isEmpty() ? "Network error" : text;
        } else {
            String text = e.getMessage();
            message = text == null || text.isEmpty() ? "Error" : text;
        }
        sendResult(callbackId, false, message);
    }

    private File projectsDir() throws IOException {
        File dir = new File(activity.getFilesDir(), "projects");
        if (!dir.isDirectory() && !dir.mkdirs()) {
            throw new IOException("Cannot create projects folder");
        }
        return dir;
    }

    private File projectFile(String name) throws IOException {
        if (name == null || !PROJECT_NAME.matcher(name).matches()) {
            throw new IOException("Invalid project name");
        }
        return new File(projectsDir(), name);
    }

    private void writeAtomic(File target, String text) throws IOException {
        File dir = target.getParentFile();
        File tmp = new File(dir, target.getName() + ".tmp");
        File bak = new File(dir, target.getName() + ".bak");

        writeText(tmp, text);

        if (target.exists()) {
            deleteFile(bak);
            if (!target.renameTo(bak)) {
                throw new IOException("Cannot back up previous file");
            }
        }
        if (!tmp.renameTo(target)) {
            if (bak.exists()) {
                bak.renameTo(target);
            }
            throw new IOException("Cannot replace file");
        }
    }

    private static void writeText(File file, String text) throws IOException {
        FileOutputStream out = new FileOutputStream(file);
        try {
            out.write(text.getBytes(StandardCharsets.UTF_8));
        } finally {
            out.close();
        }
    }

    private static String readText(File file) throws IOException {
        InputStream in = new FileInputStream(file);
        try {
            return readText(in);
        } finally {
            in.close();
        }
    }

    private static String readText(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = in.read(buffer)) != -1) {
            out.write(buffer, 0, count);
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    private static void deleteFile(File file) {
        if (file.exists()) {
            file.delete();
        }
    }

    private String displayName(Uri uri, String fallback) {
        try (Cursor cursor = activity.getContentResolver().query(
                uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (column >= 0) {
                    String name = cursor.getString(column);
                    if (name != null && !name.isEmpty()) {
                        return name;
                    }
                }
            }
        } catch (Exception ignored) {
            // fall through to the URI itself
        }
        String last = uri.getLastPathSegment();
        return last == null || last.isEmpty() ? fallback : last;
    }

    private SharedPreferences prefs() {
        return activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private String owner() {
        return prefs().getString(KEY_OWNER, "");
    }

    private String repo() {
        return prefs().getString(KEY_REPO, "");
    }

    private String token() {
        return prefs().getString(KEY_TOKEN, "");
    }
}

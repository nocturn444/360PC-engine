package dev.pc360.roomeditor;

import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

import javax.net.ssl.HttpsURLConnection;

/**
 * Minimal GitHub REST v3 client. It only reads main and only writes to a new rooms/ branch.
 * The token is used in the Authorization header and never returned or included in an error.
 */
public class GitHub {

    private static final String API = "https://api.github.com/repos/";
    private static final int TIMEOUT_MS = 30000;

    public static class ApiException extends IOException {
        public final int status;

        public ApiException(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    public String list(String owner, String repo, String token,
                       String dirPath, String ref) throws IOException {
        checkConfig(owner, repo, token);
        String path = stripSlashes(dirPath);
        String url = base(owner, repo) + "/contents";
        if (!path.isEmpty()) {
            url += "/" + encodePath(path);
        }
        url += "?ref=" + encodeQuery(ref);

        try {
            JSONArray items = new JSONArray(request("GET", url, token, null));
            JSONArray result = new JSONArray();
            for (int i = 0; i < items.length(); i++) {
                JSONObject item = items.optJSONObject(i);
                if (item == null) {
                    continue;
                }
                String name = item.optString("name", "");
                if (!name.endsWith(".lvl")) {
                    continue;
                }
                JSONObject entry = new JSONObject();
                entry.put("name", name);
                entry.put("path", item.optString("path", ""));
                entry.put("sha", item.optString("sha", ""));
                entry.put("size", item.optLong("size", 0));
                result.put(entry);
            }
            return result.toString();
        } catch (JSONException e) {
            throw new IOException("Unexpected GitHub response", e);
        }
    }

    public String read(String owner, String repo, String token,
                       String path, String ref) throws IOException {
        checkConfig(owner, repo, token);
        String clean = stripSlashes(path);
        String url = base(owner, repo) + "/contents/" + encodePath(clean)
                + "?ref=" + encodeQuery(ref);

        try {
            JSONObject item = new JSONObject(request("GET", url, token, null));
            String sha = item.optString("sha", "");
            long size = item.optLong("size", 0);
            String content = item.optString("content", "");
            String text;
            if (size > 1024 * 1024 || content.isEmpty()) {
                String blobUrl = base(owner, repo) + "/git/blobs/" + sha;
                JSONObject blob = new JSONObject(request("GET", blobUrl, token, null));
                text = decode(blob.optString("content", ""));
            } else {
                text = decode(content);
            }
            JSONObject result = new JSONObject();
            result.put("path", item.optString("path", clean));
            result.put("sha", sha);
            result.put("text", text);
            return result.toString();
        } catch (JSONException e) {
            throw new IOException("Unexpected GitHub response", e);
        }
    }

    public String upload(String owner, String repo, String token,
                         String filesJson, String title, String body) throws IOException {
        checkConfig(owner, repo, token);

        JSONArray files;
        try {
            files = new JSONArray(filesJson);
        } catch (JSONException e) {
            throw new IOException("Invalid files JSON", e);
        }

        String base = base(owner, repo);
        String branch = "rooms/" + timestamp();

        try {
            JSONObject mainRef = new JSONObject(
                    request("GET", base + "/git/ref/heads/main", token, null));
            String headSha = mainRef.getJSONObject("object").getString("sha");

            JSONObject createRef = new JSONObject();
            createRef.put("ref", "refs/heads/" + branch);
            createRef.put("sha", headSha);
            request("POST", base + "/git/refs", token, createRef.toString());

            for (int i = 0; i < files.length(); i++) {
                JSONObject file = files.getJSONObject(i);
                String path = stripSlashes(file.getString("path"));
                String text = file.optString("text", "");
                String existingSha = existingSha(base, token, path, branch);

                JSONObject put = new JSONObject();
                put.put("message", title == null || title.isEmpty()
                        ? "Update " + path : title);
                put.put("content", Base64.encodeToString(
                        text.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP));
                put.put("branch", branch);
                if (existingSha != null) {
                    put.put("sha", existingSha);
                }
                request("PUT", base + "/contents/" + encodePath(path), token, put.toString());
            }

            JSONObject pull = new JSONObject();
            pull.put("title", title == null ? "" : title);
            pull.put("head", branch);
            pull.put("base", "main");
            pull.put("body", body == null ? "" : body);
            JSONObject created = new JSONObject(
                    request("POST", base + "/pulls", token, pull.toString()));

            JSONObject result = new JSONObject();
            result.put("branch", branch);
            result.put("prUrl", created.optString("html_url", ""));
            result.put("prNumber", created.optInt("number", 0));
            return result.toString();
        } catch (JSONException e) {
            throw new IOException("Unexpected GitHub response", e);
        }
    }

    private String existingSha(String base, String token, String path, String branch)
            throws IOException {
        try {
            String url = base + "/contents/" + encodePath(path)
                    + "?ref=" + encodeQuery(branch);
            JSONObject item = new JSONObject(request("GET", url, token, null));
            String sha = item.optString("sha", "");
            return sha.isEmpty() ? null : sha;
        } catch (ApiException e) {
            if (e.status == 404) {
                return null;
            }
            throw e;
        } catch (JSONException e) {
            throw new IOException("Unexpected GitHub response", e);
        }
    }

    private static String request(String method, String url, String token, String body)
            throws IOException {
        HttpsURLConnection connection = (HttpsURLConnection) new URL(url).openConnection();
        try {
            connection.setConnectTimeout(TIMEOUT_MS);
            connection.setReadTimeout(TIMEOUT_MS);
            connection.setRequestMethod(method);
            connection.setRequestProperty("Accept", "application/vnd.github+json");
            connection.setRequestProperty("X-GitHub-Api-Version", "2022-11-28");
            connection.setRequestProperty("User-Agent", "room-editor");
            if (!token.isEmpty()) {
                connection.setRequestProperty("Authorization", "Bearer " + token);
            }

            if (body != null) {
                byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                connection.setFixedLengthStreamingMode(bytes.length);
                OutputStream out = connection.getOutputStream();
                try {
                    out.write(bytes);
                } finally {
                    out.close();
                }
            }

            int status = connection.getResponseCode();
            InputStream in = status >= 200 && status < 300
                    ? connection.getInputStream()
                    : connection.getErrorStream();
            String text = readText(in);
            if (status < 200 || status >= 300) {
                throw new ApiException(status, errorMessage(status, text));
            }
            return text;
        } finally {
            connection.disconnect();
        }
    }

    private static String errorMessage(int status, String body) {
        String message = "GitHub HTTP " + status;
        try {
            JSONObject item = new JSONObject(body);
            String field = item.optString("message", "");
            if (!field.isEmpty()) {
                message = "GitHub " + status + ": " + field;
            }
        } catch (JSONException ignored) {
            // keep the status-only message
        }
        return message;
    }

    private static String readText(InputStream in) throws IOException {
        if (in == null) {
            return "";
        }
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int count;
            while ((count = in.read(buffer)) != -1) {
                out.write(buffer, 0, count);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } finally {
            in.close();
        }
    }

    private static void checkConfig(String owner, String repo, String token) throws IOException {
        if (owner == null || owner.isEmpty() || repo == null || repo.isEmpty()) {
            throw new IOException("GitHub owner and repo are required");
        }
        if (token == null || token.isEmpty()) {
            throw new IOException("GitHub token is not set");
        }
    }

    private static String base(String owner, String repo) {
        return API + owner + "/" + repo;
    }

    private static String decode(String base64) {
        return new String(Base64.decode(base64, Base64.DEFAULT), StandardCharsets.UTF_8);
    }

    private static String stripSlashes(String path) {
        String result = path == null ? "" : path;
        while (result.startsWith("/")) {
            result = result.substring(1);
        }
        while (result.endsWith("/")) {
            result = result.substring(0, result.length() - 1);
        }
        return result;
    }

    private static String encodePath(String path) throws IOException {
        String[] parts = path.split("/", -1);
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < parts.length; i++) {
            if (i > 0) {
                result.append('/');
            }
            result.append(URLEncoder.encode(parts[i], "UTF-8").replace("+", "%20"));
        }
        return result.toString();
    }

    private static String encodeQuery(String value) throws IOException {
        String ref = value == null || value.isEmpty() ? "main" : value;
        return URLEncoder.encode(ref, "UTF-8").replace("+", "%20");
    }

    private static String timestamp() {
        SimpleDateFormat format = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
    }
}

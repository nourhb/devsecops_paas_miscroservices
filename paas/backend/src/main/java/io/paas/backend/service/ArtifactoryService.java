package io.paas.backend.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.paas.backend.dto.ArtifactListResponse;
import io.paas.backend.dto.ArtifactRecord;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

@Service
public class ArtifactoryService {

    private final HttpClient httpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(15))
        .build();

    private final ObjectMapper objectMapper;
    private final String artifactoryUrl;
    private final String repository;
    private final String username;
    private final String password;
    private final String accessToken;

    public ArtifactoryService(
        ObjectMapper objectMapper,
        @Value("${artifactory.url:}") String artifactoryUrl,
        @Value("${artifactory.repository:libs-release-local}") String repository,
        @Value("${artifactory.username:}") String username,
        @Value("${artifactory.password:}") String password,
        @Value("${artifactory.access-token:}") String accessToken
    ) {
        this.objectMapper = objectMapper;
        this.artifactoryUrl = trimTrailingSlash(artifactoryUrl);
        this.repository = repository;
        this.username = username;
        this.password = password;
        this.accessToken = accessToken;
    }

    public ArtifactListResponse listArtifacts() throws IOException, InterruptedException {
        JsonNode storageResponse = getJson("/api/storage/" + encode(repository) + "?list&deep=1&listFolders=0&mdTimestamps=1&statsTimestamps=1&includeRootPath=1");
        List<ArtifactRecord> artifacts = new ArrayList<>();

        for (JsonNode fileNode : storageResponse.path("files")) {
            if (fileNode.path("folder").asBoolean(false)) {
                continue;
            }
            String relativePath = fileNode.path("uri").asText("").replaceFirst("^/+", "");
            if (relativePath.isBlank()) {
                continue;
            }
            artifacts.add(toArtifactRecord(
                relativePath,
                fileNode.path("size").asLong(0L),
                fileNode.path("lastModified").asText(storageResponse.path("created").asText(""))
            ));
        }

        artifacts.sort(Comparator.comparing(ArtifactRecord::getCreatedAt).reversed());
        ArtifactRecord latest = artifacts.isEmpty() ? null : artifacts.get(0);
        return new ArtifactListResponse(artifacts, latest);
    }

    public ArtifactRecord getArtifactByName(String name) throws IOException, InterruptedException {
        JsonNode searchResponse = getJson("/api/search/artifact?name=" + encode(name) + "&repos=" + encode(repository));
        JsonNode firstResult = searchResponse.path("results").isArray() && searchResponse.path("results").size() > 0
            ? searchResponse.path("results").get(0)
            : null;

        if (firstResult == null || firstResult.path("uri").asText("").isBlank()) {
            throw new IllegalArgumentException("Artifact not found: " + name);
        }

        JsonNode metadata = getJsonAbsolute(firstResult.path("uri").asText());
        String path = metadata.path("path").asText("");
        String itemName = metadata.path("name").asText(name);
        String relativePath = ".".equals(path) || path.isBlank() ? itemName : path + "/" + itemName;
        String downloadUri = metadata.path("downloadUri").asText(buildDownloadUrl(relativePath));

        return new ArtifactRecord(
            itemName,
            extractVersion(itemName),
            humanReadableSize(metadata.path("size").asLong(0L)),
            metadata.path("lastModified").asText(metadata.path("created").asText("")),
            downloadUri,
            metadata.path("repo").asText(repository),
            relativePath,
            "Stored"
        );
    }

    private ArtifactRecord toArtifactRecord(String relativePath, long sizeBytes, String createdAt) {
        String fileName = relativePath.contains("/")
            ? relativePath.substring(relativePath.lastIndexOf('/') + 1)
            : relativePath;

        return new ArtifactRecord(
            fileName,
            extractVersion(fileName),
            humanReadableSize(sizeBytes),
            createdAt,
            buildDownloadUrl(relativePath),
            repository,
            relativePath,
            "Stored"
        );
    }

    private JsonNode getJson(String path) throws IOException, InterruptedException {
        ensureConfigured();
        HttpRequest request = baseRequest(URI.create(artifactoryUrl + path)).GET().build();
        return execute(request);
    }

    private JsonNode getJsonAbsolute(String uri) throws IOException, InterruptedException {
        ensureConfigured();
        HttpRequest request = baseRequest(URI.create(uri)).GET().build();
        return execute(request);
    }

    private JsonNode execute(HttpRequest request) throws IOException, InterruptedException {
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() >= 400) {
            throw new IOException("Artifactory request failed with HTTP " + response.statusCode() + ": " + response.body());
        }
        return objectMapper.readTree(response.body());
    }

    private HttpRequest.Builder baseRequest(URI uri) {
        HttpRequest.Builder builder = HttpRequest.newBuilder(uri)
            .timeout(Duration.ofSeconds(30))
            .header("Accept", "application/json");

        if (!accessToken.isBlank()) {
            return builder.header("Authorization", "Bearer " + accessToken);
        }

        if (!username.isBlank() && !password.isBlank()) {
            String auth = Base64.getEncoder().encodeToString((username + ":" + password).getBytes(StandardCharsets.UTF_8));
            return builder.header("Authorization", "Basic " + auth);
        }

        return builder;
    }

    private void ensureConfigured() {
        if (artifactoryUrl.isBlank()) {
            throw new IllegalStateException("artifactory.url is required.");
        }
        if (accessToken.isBlank() && (username.isBlank() || password.isBlank())) {
            throw new IllegalStateException("Configure either artifactory.access-token or artifactory.username/artifactory.password.");
        }
    }

    private String buildDownloadUrl(String relativePath) {
        StringBuilder builder = new StringBuilder();
        String[] parts = relativePath.split("/");
        for (int i = 0; i < parts.length; i++) {
            if (i > 0) {
                builder.append('/');
            }
            builder.append(encode(parts[i]));
        }
        return artifactoryUrl + "/" + encode(repository) + "/" + builder;
    }

    private String extractVersion(String fileName) {
        int extensionIndex = fileName.lastIndexOf('.');
        String withoutExtension = extensionIndex >= 0 ? fileName.substring(0, extensionIndex) : fileName;
        int separatorIndex = withoutExtension.lastIndexOf('-');
        if (separatorIndex < 0 || separatorIndex == withoutExtension.length() - 1) {
            return "latest";
        }
        return withoutExtension.substring(separatorIndex + 1);
    }

    private String humanReadableSize(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        double kilobytes = bytes / 1024.0;
        if (kilobytes < 1024) {
            return String.format("%.1f KB", kilobytes);
        }
        double megabytes = kilobytes / 1024.0;
        if (megabytes < 1024) {
            return String.format("%.1f MB", megabytes);
        }
        double gigabytes = megabytes / 1024.0;
        return String.format("%.2f GB", gigabytes);
    }

    private String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
    }

    private String trimTrailingSlash(String value) {
        return value == null ? "" : value.replaceAll("/+$", "");
    }
}

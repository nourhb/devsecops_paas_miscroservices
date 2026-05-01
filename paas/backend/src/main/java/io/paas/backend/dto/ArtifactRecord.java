package io.paas.backend.dto;

public class ArtifactRecord {

    private final String name;
    private final String version;
    private final String size;
    private final String createdAt;
    private final String downloadUrl;
    private final String repository;
    private final String path;
    private final String status;

    public ArtifactRecord(
        String name,
        String version,
        String size,
        String createdAt,
        String downloadUrl,
        String repository,
        String path,
        String status
    ) {
        this.name = name;
        this.version = version;
        this.size = size;
        this.createdAt = createdAt;
        this.downloadUrl = downloadUrl;
        this.repository = repository;
        this.path = path;
        this.status = status;
    }

    public String getName() {
        return name;
    }

    public String getVersion() {
        return version;
    }

    public String getSize() {
        return size;
    }

    public String getCreatedAt() {
        return createdAt;
    }

    public String getDownloadUrl() {
        return downloadUrl;
    }

    public String getRepository() {
        return repository;
    }

    public String getPath() {
        return path;
    }

    public String getStatus() {
        return status;
    }
}

package io.paas.backend.dto;

import java.util.List;

public class ArtifactListResponse {

    private final List<ArtifactRecord> artifacts;
    private final ArtifactRecord latestArtifact;

    public ArtifactListResponse(List<ArtifactRecord> artifacts, ArtifactRecord latestArtifact) {
        this.artifacts = artifacts;
        this.latestArtifact = latestArtifact;
    }

    public List<ArtifactRecord> getArtifacts() {
        return artifacts;
    }

    public ArtifactRecord getLatestArtifact() {
        return latestArtifact;
    }
}

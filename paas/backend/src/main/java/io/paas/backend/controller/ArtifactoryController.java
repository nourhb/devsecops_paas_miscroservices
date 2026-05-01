package io.paas.backend.controller;

import io.paas.backend.dto.ArtifactListResponse;
import io.paas.backend.dto.ArtifactRecord;
import io.paas.backend.service.ArtifactoryService;
import java.io.IOException;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/artifacts")
public class ArtifactoryController {

    private final ArtifactoryService artifactoryService;

    public ArtifactoryController(ArtifactoryService artifactoryService) {
        this.artifactoryService = artifactoryService;
    }

    @GetMapping
    public ArtifactListResponse getArtifacts() {
        try {
            return artifactoryService.listArtifacts();
        } catch (IllegalStateException exception) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, exception.getMessage(), exception);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "Could not load artifacts from Artifactory.", exception);
        } catch (IOException exception) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "Could not load artifacts from Artifactory.", exception);
        }
    }

    @GetMapping("/{name}")
    public ArtifactRecord getArtifact(@PathVariable String name) {
        try {
            return artifactoryService.getArtifactByName(name);
        } catch (IllegalArgumentException exception) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, exception.getMessage(), exception);
        } catch (IllegalStateException exception) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, exception.getMessage(), exception);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "Could not load artifact details from Artifactory.", exception);
        } catch (IOException exception) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "Could not load artifact details from Artifactory.", exception);
        }
    }
}

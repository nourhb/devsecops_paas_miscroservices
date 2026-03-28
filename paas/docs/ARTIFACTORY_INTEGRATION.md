# Artifactory Integration in the Pipeline

## Role of Artifactory

- **Store build artifacts:** JARs, npm packages, binaries, versioned by build number or Git tag.
- **Single source of truth** for release artifacts; downstream jobs or other systems pull by version.
- **Promotion:** Optional promotion from dev to prod repository for compliance.

## Integration points

1. **After build (Jenkins):** Publish artifacts to Artifactory using:
   - **Jenkins Artifactory Plugin** (e.g. `rtUpload`), or
   - **REST API** / `jfrog` CLI: `jfrog rt u dist/*.tgz generic-local/my-app/1.2.3/`
2. **Versioning:** Use `BUILD_NUMBER`, Git tag, or semantic version from `package.json`/pom.
3. **Later stages:** Other jobs (e.g. deploy, compliance) can download from Artifactory by version instead of rebuilding.

## Example (conceptual)

```groovy
// Jenkins
stage('Publish') {
  steps {
    sh "npm run build"
    rtUpload(
      serverId: "artifactory",
      spec: """
        {
          "files": [{
            "pattern": "dist/*.tgz",
            "target": "generic-local/${APP_NAME}/${BUILD_NUMBER}/"
          }]
        }
      """
    )
  }
}
```

## Placement in pipeline

- **After** unit tests and **before or after** Docker build.
- Docker image is stored in Harbor; application artifacts (non-container) in Artifactory.
- PaaS UI can show “Artifact version” (e.g. link to Artifactory) for traceability.

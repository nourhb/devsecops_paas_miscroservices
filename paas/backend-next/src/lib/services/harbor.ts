import axios from "axios";

export interface HarborPushResult {
  pushed: boolean;
  imageRef: string;
  digest?: string;
  repository?: string;
}

function getHarborClient() {
  const baseUrl = process.env.HARBOR_URL;
  const username = process.env.HARBOR_USERNAME;
  const password = process.env.HARBOR_PASSWORD;

  if (!baseUrl || !username || !password) {
    throw new Error(
      "Harbor configuration missing (HARBOR_URL/USERNAME/PASSWORD).",
    );
  }

  return axios.create({
    baseURL: baseUrl.replace(/\/+$/, "") + "/api/v2.0",
    auth: {
      username,
      password,
    },
  });
}

export async function createRepository(
  projectName: string,
  repositoryName: string,
): Promise<void> {
  const client = getHarborClient();

  // Harbor treats repositories as resources under a project.
  // Creating a repository is typically implicit on push, but we can ensure
  // the project exists and then create a dummy artifact if necessary.
  try {
    await client.get(`/projects/${encodeURIComponent(projectName)}`);
  } catch (error) {
    const message =
      axios.isAxiosError(error) && error.response
        ? `Harbor project ${projectName} not found or inaccessible: ${error.response.status}`
        : (error as Error).message;
    throw new Error(message);
  }

  // No-op for most Harbor setups; repository will be created on first push.
  // Leave this as a logical placeholder in case you want to call
  // the repository API explicitly later.
}

export async function deleteRepository(
  projectName: string,
  repositoryName: string,
): Promise<void> {
  const client = getHarborClient();
  try {
    await client.delete(
      `/projects/${encodeURIComponent(
        projectName,
      )}/repositories/${encodeURIComponent(repositoryName)}`,
    );
  } catch {
    // ignore if not found or cannot be deleted
  }
}

export async function registerPushedImage(
  imageRef: string,
): Promise<HarborPushResult> {
  const client = getHarborClient();

  // imageRef format: harbor.example.com/project/repo:tag
  const withoutRegistry = imageRef.split("/").slice(1).join("/");
  const [projectAndRepo, tag] = withoutRegistry.split(":");
  const [projectName, ...repoParts] = projectAndRepo.split("/");
  const repositoryName = repoParts.join("/");

  try {
    const { data } = await client.get(
      `/projects/${encodeURIComponent(
        projectName,
      )}/repositories/${encodeURIComponent(repositoryName)}/artifacts`,
      {
        params: { with_tag: true, q: `tags=${tag}` },
      },
    );

    const artifact = Array.isArray(data) && data.length > 0 ? data[0] : null;

    return {
      pushed: !!artifact,
      imageRef,
      digest: artifact?.digest,
      repository: `${projectName}/${repositoryName}`,
    };
  } catch (error) {
    const message =
      axios.isAxiosError(error) && error.response
        ? `Harbor error: ${error.response.status} ${error.response.statusText}`
        : (error as Error).message;
    throw new Error(message);
  }
}

export async function getImageTags(
  projectName: string,
  repositoryName: string,
): Promise<string[]> {
  const client = getHarborClient();

  try {
    const { data } = await client.get(
      `/projects/${encodeURIComponent(
        projectName,
      )}/repositories/${encodeURIComponent(repositoryName)}/artifacts`,
      {
        params: { with_tag: true },
      },
    );

    const artifacts = Array.isArray(data) ? data : [];
    const tags = new Set<string>();
    for (const art of artifacts) {
      for (const tag of art.tags ?? []) {
        if (tag.name) tags.add(tag.name as string);
      }
    }
    return Array.from(tags);
  } catch (error) {
    const message =
      axios.isAxiosError(error) && error.response
        ? `Harbor error: ${error.response.status} ${error.response.statusText}`
        : (error as Error).message;
    throw new Error(message);
  }
}



const UUID_SEGMENT = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isUuid(value: string): boolean {
    return UUID_SEGMENT.test(value);
}

export function resolveProjectIdFromPath(pathname: string): string | null {
    const path = pathname.split("?")[0]?.replace(/\/+$/, "") || "";
    const projectDetail = path.match(/^\/projects\/([^/]+)$/);
    if (projectDetail?.[1] && projectDetail[1] !== "create" && isUuid(projectDetail[1])) {
        return projectDetail[1];
    }
    const projectEdit = path.match(/^\/projects\/([^/]+)\/edit$/);
    if (projectEdit?.[1] && isUuid(projectEdit[1])) {
        return projectEdit[1];
    }
    const scoped = path.match(/^\/(pipeline|security|docker|monitoring)\/([^/]+)$/);
    if (scoped?.[2] && isUuid(scoped[2])) {
        return scoped[2];
    }
    return null;
}

export function resolveDeploymentIdFromPath(pathname: string): string | null {
    const path = pathname.split("?")[0]?.replace(/\/+$/, "") || "";
    const match = path.match(/^\/deployments\/([^/]+)$/);
    if (match?.[1] && isUuid(match[1])) {
        return match[1];
    }
    return null;
}

export function isProjectScopedPath(pathname: string): boolean {
    return resolveProjectIdFromPath(pathname) !== null || resolveDeploymentIdFromPath(pathname) !== null;
}

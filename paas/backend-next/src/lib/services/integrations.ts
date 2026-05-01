import axios from 'axios';
import { env } from '../env';
const TIMEOUT = 5000;
async function probe(url?: string, path = '/') {
    if (!url)
        return { ok: false, reason: 'not_configured' };
    try {
        const res = await axios.get(url.replace(/\/$/, '') + path, { timeout: TIMEOUT });
        return { ok: res.status >= 200 && res.status < 400, status: res.status };
    }
    catch (err: any) {
        return { ok: false, reason: err.message || 'error' };
    }
}
export async function checkJenkins() {
    return probe(env.JENKINS_URL, '/api/json');
}
export async function checkHarbor() {
    return probe(env.HARBOR_URL, '/api/v2.0/projects');
}
export async function checkArgoCD() {
    return probe(env.ARGOCD_URL, '/api/v1/applications');
}
export async function checkSonar() {
    return probe(env.SONAR_URL, '/api/system/status');
}
export async function checkTrivy() {
    return probe(env.TRIVY_BASE_URL, '/');
}
export async function checkOPA() {
    return probe(env.OPA_BASE_URL || env.OPA_URL, '/health');
}
export async function checkPrometheus() {
    return probe(env.PROMETHEUS_BASE_URL, '/api/v1/status/runtimeinfo');
}
export async function checkGrafana() {
    return probe(env.GRAFANA_URL || env.GRAFANA_BASE_URL, '/api/health');
}
export async function verifyAll() {
    const results = {
        jenkins: await checkJenkins(),
        harbor: await checkHarbor(),
        argocd: await checkArgoCD(),
        sonar: await checkSonar(),
        trivy: await checkTrivy(),
        opa: await checkOPA(),
        prometheus: await checkPrometheus(),
        grafana: await checkGrafana(),
    };
    return results;
}

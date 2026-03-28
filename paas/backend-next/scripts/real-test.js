/**
 * Real test: hits the live PaaS backend and verifies health, infrastructure, and API responses.
 * Run with: npm run test:real (or node scripts/real-test.js)
 * Ensure backend is running: npm run dev (port 4000)
 *
 * Optional flags:
 *   --base-url <url>   e.g. node scripts/real-test.js --base-url http://localhost:4000 (works on Windows)
 *   --deploy           trigger POST /api/deploy for first project
 *
 * Windows PowerShell: $env:BASE_URL="http://localhost:4000"; npm run test:real
 */

const axios = require('axios');

const argv = process.argv.slice(2);
const baseUrlIdx = argv.indexOf('--base-url');
const BASE = baseUrlIdx >= 0 && argv[baseUrlIdx + 1]
  ? argv[baseUrlIdx + 1]
  : (process.env.BASE_URL || 'http://localhost:4000');
const triggerDeploy = argv.includes('--deploy');

async function get(url, label) {
  try {
    const res = await axios.get(url, { timeout: 10000 });
    return { ok: res.status >= 200 && res.status < 300, status: res.status, data: res.data, label };
  } catch (err) {
    const status = err.response?.status;
    const data = err.response?.data;
    return { ok: false, status: status || 0, data: data || err.message, label };
  }
}

async function post(url, body, label) {
  try {
    const res = await axios.post(url, body, {
      headers: { 'Content-Type': 'application/json' },
      timeout: 15000,
    });
    return { ok: res.status >= 200 && res.status < 300, status: res.status, data: res.data, label };
  } catch (err) {
    const status = err.response?.status;
    const data = err.response?.data;
    return { ok: false, status: status || 0, data: data || err.message, label };
  }
}

async function run() {
  console.log('Real test – PaaS backend at', BASE, '\n');

  const results = [];

  // 1. Health
  const health = await get(`${BASE}/api/health`, 'GET /api/health');
  results.push(health);
  console.log(health.ok ? 'PASS' : 'FAIL', health.label, health.status, health.ok ? '' : JSON.stringify(health.data));

  // 2. Infrastructure connectivity
  const jenkins = await get(`${BASE}/api/test/jenkins`, 'GET /api/test/jenkins');
  results.push(jenkins);
  console.log(jenkins.ok ? 'PASS' : 'FAIL', jenkins.label, jenkins.status, jenkins.ok ? '' : (jenkins.data?.error || jenkins.data));

  const harbor = await get(`${BASE}/api/test/harbor`, 'GET /api/test/harbor');
  results.push(harbor);
  console.log(harbor.ok ? 'PASS' : 'FAIL', harbor.label, harbor.status, harbor.ok ? '' : (harbor.data?.error || harbor.data));

  const argocd = await get(`${BASE}/api/test/argocd`, 'GET /api/test/argocd');
  results.push(argocd);
  console.log(argocd.ok ? 'PASS' : 'FAIL', argocd.label, argocd.status, argocd.ok ? '' : (argocd.data?.error || argocd.data));

  const k8s = await get(`${BASE}/api/test/kubernetes`, 'GET /api/test/kubernetes');
  results.push(k8s);
  console.log(k8s.ok ? 'PASS' : 'FAIL', k8s.label, k8s.status, k8s.ok ? '' : (k8s.data?.error || k8s.data));

  // 3. Projects list
  const projects = await get(`${BASE}/api/project`, 'GET /api/project');
  results.push(projects);
  const projectList = Array.isArray(projects.data) ? projects.data : [];
  console.log(projects.ok ? 'PASS' : 'FAIL', projects.label, projects.status, projectList.length, 'projects');

  // 4. Metrics (dashboard)
  const metrics = await get(`${BASE}/api/metrics`, 'GET /api/metrics');
  results.push(metrics);
  const hasMetrics = metrics.ok && metrics.data && (metrics.data.cluster != null || metrics.data.pipelines != null);
  console.log(hasMetrics ? 'PASS' : 'FAIL', metrics.label, metrics.status, metrics.ok ? 'cluster + pipelines + security' : (metrics.data?.error || metrics.data));

  // 5. Optional: trigger deploy for first project
  if (triggerDeploy && projectList.length > 0) {
    const projectId = projectList[0].id;
    const deploy = await post(
      `${BASE}/api/deploy`,
      { projectId, branch: 'main', namespace: 'default' },
      'POST /api/deploy'
    );
    results.push(deploy);
    console.log(deploy.ok ? 'PASS' : 'FAIL', deploy.label, deploy.status, deploy.ok ? (deploy.data?.deploymentId || deploy.data) : (deploy.data?.error || deploy.data));
  }

  const passed = results.filter((r) => r.ok).length;
  const failed = results.filter((r) => !r.ok).length;
  console.log('\n---');
  console.log('Result:', passed, 'passed,', failed, 'failed');

  if (failed > 0) {
    process.exit(1);
  }
  process.exit(0);
}

run().catch((err) => {
  console.error('Real test error:', err.message);
  process.exit(1);
});

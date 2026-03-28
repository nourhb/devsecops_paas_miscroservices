const axios = require('axios');
const BASE = process.env.BASE_URL || 'http://localhost:4000';

async function run() {
  console.log('Requesting integration status from backend:', BASE + '/api/integrations/status');
  try {
    const r = await axios.get(`${BASE}/api/integrations/status`);
    console.log('Integration status:');
    console.dir(r.data, { depth: null });
    process.exit(0);
  } catch (err) {
    console.error('Failed to fetch integration status:', err.message || err);
    process.exit(2);
  }
}

run();

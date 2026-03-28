import minimist from "minimist";
import axios from "axios";

const args = minimist(process.argv.slice(2));
const baseUrl = args.baseUrl || "http://localhost:4000";
const projectId = args.projectId;

if (!projectId) {
  console.error("Usage: npm run test:deployment -- --projectId=<id> [--baseUrl=http://localhost:4000]");
  process.exit(1);
}

async function main() {
  const { data } = await axios.get(`${baseUrl}/api/deployments`, {
    params: { projectId },
  });

  console.log("Deployments:", data);
}

main().catch((err) => {
  console.error(err?.response?.data || err.message);
  process.exit(1);
});


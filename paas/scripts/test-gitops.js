import minimist from "minimist";
import axios from "axios";

const args = minimist(process.argv.slice(2));
const baseUrl = args.baseUrl || "http://localhost:4000";

async function main() {
  const { data: projects } = await axios.get(`${baseUrl}/api/project`);
  console.log("Projects:", projects.map((p) => ({ id: p.id, name: p.name || p.projectName })));
  console.log("Ensure ArgoCD is watching the GitOps repo for these apps.");
}

main().catch((err) => {
  console.error(err?.response?.data || err.message);
  process.exit(1);
});


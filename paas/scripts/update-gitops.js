#!/usr/bin/env node
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const yaml = require('js-yaml');

function usage() {
  console.error('Usage: update-gitops.js --repoUrl=git@... or https://... [--token=TOKEN] --branch=main --workdir=tmpdir --valuesPath=charts/app/values.yaml --imageKey=image.tag --imageTag=registry/repo:tag');
  process.exit(2);
}

const argv = require('minimist')(process.argv.slice(2));
if (!argv.repoUrl || !argv.valuesPath || !argv.imageTag) usage();

const repoUrl = argv.repoUrl;
const token = argv.token; // optional; not used for SSH
const branch = argv.branch || 'main';
const workdir = argv.workdir || path.join(os.tmpdir(), `gitops-${Date.now()}`);
const valuesPath = argv.valuesPath;
const imageKey = argv.imageKey || 'image.tag';
const imageTag = argv.imageTag;

try {
  console.log('Preparing to update GitOps repo...');

  // Determine clone URL: if SSH-style (git@) or explicit ssh flag, clone as-is.
  let cloneUrl = repoUrl;
  if (repoUrl.startsWith('https://')) {
    if (token) {
      // inject token for HTTPS auth
      cloneUrl = repoUrl.replace('https://', `https://${token}@`);
    } else {
      throw new Error('HTTPS repoUrl requires --token. For SSH use git@... URL or provide SSH access via agent.');
    }
  }

  console.log('Cloning GitOps repo:', repoUrl);
  execSync(`git clone --depth 1 --branch ${branch} ${cloneUrl} ${workdir}`, { stdio: 'inherit' });

  const fullValuesPath = path.join(workdir, valuesPath);
  if (!fs.existsSync(fullValuesPath)) {
    console.error('Values file not found:', fullValuesPath);
    process.exit(3);
  }

  console.log('Loading values file:', fullValuesPath);
  const content = fs.readFileSync(fullValuesPath, 'utf8');
  const doc = yaml.load(content) || {};

  // set nested key like 'image.tag' to imageTag
  const parts = imageKey.split('.');
  let cur = doc;
  for (let i = 0; i < parts.length - 1; i++) {
    const p = parts[i];
    if (cur[p] === undefined || cur[p] === null) cur[p] = {};
    cur = cur[p];
  }
  cur[parts[parts.length - 1]] = imageTag;

  const out = yaml.dump(doc, { lineWidth: -1 });
  fs.writeFileSync(fullValuesPath, out, 'utf8');

  // commit and push
  execSync(`git -C ${workdir} add ${valuesPath}`, { stdio: 'inherit' });
  execSync(`git -C ${workdir} commit -m "chore: update image to ${imageTag}" || true`, { stdio: 'inherit' });
  execSync(`git -C ${workdir} push origin ${branch}`, { stdio: 'inherit' });

  console.log('GitOps values updated and pushed successfully');
  process.exit(0);
} catch (err) {
  console.error('Error updating gitops:', err && err.message ? err.message : err);
  process.exit(4);
}

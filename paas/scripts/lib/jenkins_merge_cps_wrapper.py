#!/usr/bin/env python3
"""Merge CPS wrapper into paas-deploy config.xml (CDATA or XML-escaped script)."""
from __future__ import annotations

import re
from xml.sax.saxutils import escape

PAAS_DIR = "/var/jenkins_home/paas"
MARKER = "paas-deploy-stages-load-20260620-cps-split"
BUNDLE = "helm-portable-20260620-cps-split"
STAGES = f"{PAAS_DIR}/paas-deploy-stages.groovy"

SPLIT_FILES: tuple[tuple[str, str], ...] = (
    ("paasLoadH1", "paas-deploy-load-h1.groovy"),
    ("paasLoadH2", "paas-deploy-load-h2.groovy"),
    ("paasLoadH3", "paas-deploy-load-h3.groovy"),
    ("paasStagesVars", "paas-deploy-stages-vars.groovy"),
    ("paasStagesP1", "paas-deploy-stages-p1.groovy"),
    ("paasStagesP2", "paas-deploy-stages-p2.groovy"),
    ("paasStagesP3", "paas-deploy-stages-p3.groovy"),
)

CPS_FLOW = "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"
CDATA_SCRIPT = re.compile(
    rf'(<definition\b[^>]*class="{re.escape(CPS_FLOW)}"[^>]*>\s*<script>\s*<!\[CDATA\[)'
    r"([\s\S]*?)"
    r"(\]\]>\s*</script>)",
    re.I,
)
PLAIN_SCRIPT = re.compile(
    rf'(<definition\b[^>]*class="{re.escape(CPS_FLOW)}"[^>]*>\s*<script>)'
    r"([\s\S]*?)"
    r"(</script>)",
    re.I,
)


def build_wrapper(
    paas_dir: str = PAAS_DIR,
    marker: str = MARKER,
    bundle: str = BUNDLE,
    stages_path: str | None = None,
) -> str:
    """Assembled monolith load + paas.runPaasDeploy()."""
    stages = stages_path or f"{paas_dir}/paas-deploy-stages.groovy"
    return f"""// {marker}
def paasDir = '{paas_dir}'
def paasDeployStages = '{stages}'
def agentLabel = params.JENKINS_AGENT_LABEL?.trim() ?: ""
def paasRequireFreshStages = {{
  if (!fileExists(paasDeployStages)) {{
    error("Missing ${{paasDeployStages}} — run: bash paas/scripts/lib/assemble-paas-deploy-monolith.sh")
  }}
  def stagesText = readFile(paasDeployStages)
  if (!stagesText.contains('{bundle}')) {{
    error("Stale monolith (missing {bundle}) — run: bash paas/scripts/lib/assemble-paas-deploy-monolith.sh")
  }}
  if (!stagesText.contains('def runPaasDeploy()')) {{
    error("Stale monolith (missing def runPaasDeploy()) — run: bash paas/scripts/lib/assemble-paas-deploy-monolith.sh")
  }}
  if (!stagesText.contains('def coerceHarborHostForCosign')) {{
    error("Stale monolith (missing helpers) — run: bash paas/scripts/lib/assemble-paas-deploy-monolith.sh")
  }}
  if (!stagesText.contains('return this')) {{
    error("Stale monolith (missing return this) — run: bash paas/scripts/lib/assemble-paas-deploy-monolith.sh")
  }}
  if (stagesText.count('def runPaasDeploy()') != 1) {{
    error("Stale monolith (duplicate def runPaasDeploy) — run: bash paas/scripts/lib/fix-p3-no-self-invoke.sh && assemble-paas-deploy-monolith.sh")
  }}
  def paas = load paasDeployStages
  paas.runPaasDeploy()
}}
if (!agentLabel || agentLabel == 'built-in') {{
  println "[paas] node: default Built-In Node (agentLabel=${{agentLabel ?: 'empty'}})"
  node {{
    paasRequireFreshStages()
  }}
}} else {{
  println "[paas] node: agentLabel=${{agentLabel}}"
  node(agentLabel) {{
    paasRequireFreshStages()
  }}
}}
"""


def merge_pipeline_script(config_xml: str, groovy: str) -> str:
    m = CDATA_SCRIPT.search(config_xml)
    if m:
        inner = groovy.replace("]]>", "]]]]><![CDATA[>")
        return config_xml[: m.start(2)] + inner + config_xml[m.end(2) :]
    m = PLAIN_SCRIPT.search(config_xml)
    if not m:
        raise ValueError("Pipeline script block not found in config.xml (no CDATA or plain <script>)")
    if m.group(2).lstrip().startswith("<![CDATA["):
        raise ValueError("Malformed script block: CDATA opener without CDATA regex match")
    inner = escape(groovy)
    return config_xml[: m.start(2)] + inner + config_xml[m.end(2) :]


def _xml_has(config_xml: str, needle: str) -> bool:
    if needle in config_xml:
        return True
    escaped = needle.replace("(", "&#40;").replace(")", "&#41;").replace("'", "&#39;")
    return escaped in config_xml


def live_wrapper_ok(config_xml: str) -> list[str]:
    bad: list[str] = []
    if "Stale stages bundle (missing runPaasDeploy in p3)" in config_xml:
        bad.append("OLD stale check still present")
    has_monolith = _xml_has(config_xml, "load paasDeployStages") and _xml_has(
        config_xml, "paas.runPaasDeploy()"
    )
    has_broken_split = _xml_has(config_xml, "load paasStagesP3") and _xml_has(
        config_xml, "load paasLoadH1"
    )
    if has_broken_split and not has_monolith:
        bad.append(
            "broken 7-file split wrapper (CPS load does not expose methods on parent) — use monolith load"
        )
    if not has_monolith:
        bad.append("missing load paasDeployStages + paas.runPaasDeploy()")
    return bad

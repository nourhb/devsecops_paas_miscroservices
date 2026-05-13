/**
 * Short, first-person blurbs for tooltips. Written like release notes you’d leave for a teammate.
 */
export const hints = {
    nav: {
        dashboard: "My home base: I check here first for project count, cluster-ish signals, and whether scanners still talk to us.",
        platformHub: "Where I wire URLs and creds for Jenkins, Sonar, Harbor, K8s, etc. If something’s ‘down’ in the app, I usually start here.",
        cluster: "Live Kubernetes tables when the API works; otherwise you’ll see project rollups so the screen isn’t empty.",
        clusterNamespaces: "Real Namespace objects from the cluster—not the same list as app ‘target namespaces’ in projects.",
        artifacts: "Build outputs we’ve seen (images, metadata). Handy when I forget what tag actually shipped.",
        projects: "Every app registered in this workspace: open one to build, deploy, or stare at pipeline state.",
        newProject: "Registers a repo + branch so Jenkins and GitOps know what to build. I fill this once per app.",
        account: "Name, email, password—nothing fancy, just my profile on this control plane."
    },
    topNav: {
        userLine: "Who I’m logged in as and my role (admin sees everyone’s projects; developers mostly see their own).",
        mobileHub: "On a small screen the sidebar hides—I jump here to reach Integrations quickly.",
        theme: "I flip this when I’m demo-ing in a dark room or the sun hits my screen. Preference stays on this browser.",
        logout: "Ends my session here. I use it on shared machines so the next person doesn’t inherit my Jenkins view."
    },
    dashboard: {
        hero: "A deliberately dense overview: delivery stats, security rollups, and integration health. Nothing here deploys anything by itself.",
        unifiedCard: "This box is the 30-second story: build backend → optional scanners → image → GitOps. Your Jenkinsfile is still the boss.",
        totalProjects: "Rows in our DB, not ‘pods’. I use it to see if anyone’s been onboarding without telling me.",
        runningPods: "From K8s when connected; otherwise an honest rollup from deployment SUCCESS rows so the ratio isn’t fake.",
        securityScore: "A blended number from the tools we could reach—useful for trending, not for auditors without context.",
        liveTools: "Integrations that answered a ping recently. Zero doesn’t always mean broken; sometimes we’re in sim mode or offline.",
        clusterWorkload: "Pods / services / deployments snapshot. If it’s flat, either the cluster’s empty or the kubeconfig isn’t mounted right.",
        deliveryOutcome: "Finished deployments bucketed into success vs still busy vs failed. I match this to Jenkins’ classic Status page when in doubt.",
        securityPosture: "Samples recent projects and hits the same APIs as the Security tab—so if a donut is empty, I check env vars.",
        toolHealth: "Pie of what the platform thinks is ‘live’ vs ‘degraded’ tooling. Correlates with Platform hub, not with production uptime.",
        failures: "I keep an eye here so I’m not hunting through email when someone’s deploy turned red.",
        projectsTable: "Quick links into each app. Yellow rows usually mean ‘still deploying’ or ‘last run failed’.",
        platformHealth: "Three at-a-glance tiles: cluster shape from live K8s or rollups, security Finding-ish totals, delivery success rate.",
        quickActions: "Shortcuts I still use daily—cluster table, integration map, artifact list—without hunting the left rail.",
        projectBoard: "Build / deploy / pod / image columns come straight from our project rows; they lag Jenkins console by one poll cycle.",
        latestFailures: "Last bad deployments with a snippet of the failure message. I click through to the full console tail.",
        toolSignals: "Truncated copy of Platform hub groups so I don’t have to tab away during stand-up.",
        latestArtifacts: "What we’ve indexed from recent builds—if it’s empty, either nothing archived yet or permissions blocked the fetch.",
        recentDeployments: "Latest deploy rows we polled from Jenkins or Tekton—chronological with relative times; I hover the time cell when I need the exact instant."
    },
    integrations: {
        header: "This page is our integration checklist: what’s configured, what still needs URLs, and how to unblock delivery.",
        envCard: "Some panels read process env (Prometheus base URL, etc.). I treat mismatches here as ‘why is prod different from dev’ moments.",
        categoryCard: "Each big card is a tool family from the backend—the paragraph under the title is the real blurb; I watch the wired count to see what’s still placeholder.",
        toolingGroup: "Cluster/env signal board: ‘Live’ is a probe we liked on the last poll, not a contractual SLO.",
        deliveryChecklist: "Minimum wiring before I believe builds can reach GitOps + Argo + public URLs; red rows mean missing env, not ‘your app is down’.",
        runtimeSignalsHeading: "Quick probe board the server compiled from env/cluster—good for stand-up, not for paging production.",
        catalogHeading: "Everything the backend says we can deep-link or open—missing URLs almost always mean a missing env on the Next server.",
        loadError: "The integrations API bailed—usually session, route, or the platform service never started.",
        emptyCatalog: "The API answered but sent zero categories—I’d check the server build and that the metadata endpoint isn’t stubbed."
    },
    projects: {
        list: "Anything we’ve registered. I sort mentally by ‘has it ever deployed’ using the status chips.",
        create: "I point at a Git URL, pick a branch, and the platform creates Jenkins jobs + namespace conventions. Double-check image names before first push.",
        detailHeader: "One app’s cockpit: build, deploy, security, GitOps. Most buttons fan out to Jenkins or the cluster via this backend.",
        edit: "Metadata only here—repo URL, branch, toggles. Changing Git often means re-syncing Jenkins jobs afterward.",
        operations: "Where I hammer build / deploy / rollback and peek at reachability. Nothing here runs locally—it all fans out to the configured backend.",
        deployments: "History table with failure snippets; View jumps to the deployment detail with the long console chunk.",
        argoCard: "Snapshot of the Argo app for this project—nice for demos, still not a replacement for argocd’s UI when sync fights you.",
        repositoryCard: "Static fields we stored at onboarding: Git URL, branch, target namespace, detected stack.",
        runtimeCard: "Stuff that changes as polls return: image tag, pod status, which build provider answered last.",
        scaffoldingCard: "Why Dockerfile vs template—when someone asks ‘who generated this chart’, I point here.",
        platformAreas: "Deep links into pipeline, security, monitoring, docker—same destinations the sidebar uses, just contextualized.",
        buildLogsCard: "Cached build stdout from the last sync—empty means Jenkins hasn’t produced text we could pull yet.",
        deploymentLogsCard: "Post-build trail (registry / GitOps / policy). Still cached text, not an active kubectl attach."
    },
    cluster: {
        header: "If kube works, it’s real pod lists. If not, I still get honest counts from project status so the team isn’t staring at a blank table.",
        namespaceFilter: "Cluster-wide means everything I can list; picking a namespace scopes pods/services/deployments together.",
        logs: "Pod logs need a live API; CI/CD logs below work off what we stored from Jenkins even when K8s is down."
    },
    clusterNamespaces: {
        header: "Straight from the Namespace API—useful to reconcile ‘why doesn’t my app namespace exist yet’ vs Argo lag."
    },
    monitoring: {
        header: "Prometheus charts + this project’s namespace + Argo + log buffers. Some panels need the cluster; others only need our DB.",
        snapshotError: "Usually Prometheus, cosign rollups, or kube RBAC threw—scroll the error text, it’s often specific.",
        pageHeading: "Observability for one project on a single scroll—charts, kube tables, Argo, and three log tabs.",
        cpuInstant: "One Prometheus-derived percentage—read the subtitle if Prom isn’t wired; otherwise it’s cluster node headroom.",
        memInstant: "Sibling to CPU; same Prom window, so if one lies they both might.",
        deployBuildStrip: "Badges from our project row, not live Prom—good for matching Jenkins without pretending it’s metrics.",
        namespaceImage: "Target namespace plus the image tag we last reconciled into the record.",
        cpuTrend: "query_range chart for the last hour—empty usually means missing Prom or an empty series.",
        memTrend: "Memory trend twin—if it’s flat at zero, don’t panic until you confirm the scrape.",
        podsByPhase: "Pods only inside this app’s namespace; counts come from a normal kube list call.",
        workloadsLogs: "Same log API as Cluster—pick a pod, View, then read the textarea below.",
        gitopsSnapshot: "Argo health/sync for this app; unreachable text is the server being honest about auth or networking.",
        supplyChainRollups: "Workspace-wide counters (signing, failed builds, etc.)—I remind myself this isn’t scoped to just this repo.",
        logTabs: "Build + deploy buffers we stored, or a live pod tail—three tabs so I don’t paste three URLs in Slack.",
        grafanaJump: "Advanced dashboards stay in Grafana; this page is the quick companion inside the app."
    },
    pipeline: {
        header: "Project-level pipeline view: delivery checklist, live Jenkins stages when wfapi exists, and links into deployments.",
        pageHeading: "The CI/CD page I send people when they ask ‘where is the Jenkinsfile stuff’—stages, buttons, logs together.",
        deliveryPath: "Five high-level bubbles; under the hood the numbered Jenkins steps still run in order.",
        jenkinsSteps: "Every paas-deploy step—Live vs Est. depends on Pipeline Stage View; without wfapi I still read the checklist.",
        jenkinsActions: "Same trigger APIs as the project page, just closer to the stage list so I don’t bounce tabs.",
        argoPanel: "GitOps health sitting next to Jenkins so I don’t forget the cluster after a green compile.",
        pipelineSecurity: "Dependency-Track slice from the pipeline context—can trail the Security screen by one refresh cycle.",
        buildSecuritySummary: "On-call shorthand: worst build badge + roughest vuln tier—good for paging, thin for deep dives.",
        buildConsole: "Buffered Jenkins stdout—if it’s empty the job hasn’t synced into our text store yet.",
        deploymentConsole: "Post-build stages: registry, Helm, policy, Argo notes—again buffered, not magic live streaming."
    },
    deployment: {
        header: "One deployment row: what we thought the URL was, build number, and the console tail. I trust classic Jenkins over Blue Ocean when they disagree.",
        deployId: "Internal row ID for this deploy—I paste it when two different jobs both claim ‘build 142’.",
        failedCallout: "Structured failureReason/failureMessage when Jenkins gave them to us; otherwise I live in the console card.",
        liveApp: "URL recorded when we marked DEPLOYED; the reachability badge is a simple HTTP poke from the platform.",
        artifact: "Image ref we captured for this run—digest shows up when the registry metadata came back clean.",
        console: "Tail of what we buffered (last ~5k chars) with angry highlighting if it failed—full log still lives in Jenkins."
    },
    security: {
        header: "Per-project security calls (Sonar, DT, Trivy, cosign summaries). Empty charts usually mean missing keys or image tags.",
        overviewTitle: "Everything we could scrape for this project ID—Sonar gate, scanners, signing—empty widgets mean missing config more often than ‘zero bugs’.",
        globalScore: "Blended score for the dashboard vibe; I still read each widget before I tell anyone we’re ‘green’.",
        sonarGate: "Live quality gate from Sonar’s API for this key—don’t confuse it with DT’s idea of criticality.",
        depTrackVsTrivy: "Side-by-side severities from two scanners—I look for arguments when one screams and the other shrugs.",
        policySignals: "Cosign + policy engine + OPA-ish counters—Kyverno actually runs only when the cluster hook is wired.",
        analysisCard: "Dependency-Track narrative + severity table + a few hot findings—my triage starter pack.",
        trivyCard: "Plain counts from the last Trivy hop we could make—useful when DT is slow but kube still has an image digest.",
        enforcementCard: "What we think about signing and deploy allowance—when this disagrees with reality I check cluster RBAC and pipeline order."
    },
    docker: {
        header: "Docker build/push flow for this project when we’re not on the full Jenkinsfile path—still talks to the same backend jobs in many setups.",
        pageHeading: "Lightweight image loop when I don’t want the full pipeline page—build/push still hit platform APIs.",
        imageHistory: "Append-only-ish table of what we recorded for this repo—good for ‘what tag did Tuesday ship’ questions."
    },
    artifacts: {
        header: "Things Jenkins (or the platform) archived that we surface for download or audit—not a full Harbor mirror.",
        latestImage: "The newest row our indexer knows about—might lag Harbor or retention policies by a bit.",
        registrySummary: "Counts + metadata snapshot; not a replacement for logging into the registry UI.",
        table: "Everything in this workspace view with download links when the backend stored them."
    },
    account: {
        header: "I update my profile here; OAuth users might still have email managed upstream—if something’s greyed out, that’s why.",
        pageHeading: "Self-serve name/password tweaks; Keycloak folks read the banner first so we don’t fight IdP resets."
    },
    podsPanel: {
        header: "Mini cluster view on the dashboard—same pod API as Cluster status, just fewer columns."
    }
} as const;

import Link from "next/link";

export default function Home() {
  return (
    <main style={{ padding: "2rem", fontFamily: "system-ui" }}>
      <h1>DevSecOps PaaS</h1>
      <p>Backend API is running.</p>
      <ul>
        <li>
          <Link href="/api/health">Health check</Link> — <code>/api/health</code>
        </li>
        <li>
          <Link href="/api/project">Projects</Link> — <code>/api/project</code>
        </li>
        <li>
          <Link href="/api/metrics">Metrics</Link> — <code>/api/metrics</code>
        </li>
      </ul>
    </main>
  );
}

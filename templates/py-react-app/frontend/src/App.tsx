import { useEffect, useState } from "react";

type Health = { ok: boolean; version: string };

export default function App() {
  const [health, setHealth] = useState<Health | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/health")
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then(setHealth)
      .catch((e: Error) => setError(e.message));
  }, []);

  return (
    <main style={{ fontFamily: "system-ui, sans-serif", padding: 24 }}>
      <h1>app</h1>
      {error && <p>API unreachable: {error}</p>}
      {health && <p>API {health.ok ? "up" : "down"}, version {health.version}</p>}
    </main>
  );
}

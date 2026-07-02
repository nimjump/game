"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { adminLogin, adminMe } from "@/lib/api";

export default function LoginPage() {
  const router = useRouter();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error,    setError]    = useState("");
  const [loading,  setLoading]  = useState(false);
  const [checking, setChecking] = useState(true);

  // Already logged in? Skip straight past the login form.
  useEffect(() => {
    adminMe().then(authed => {
      if (authed) router.replace("/");
      else setChecking(false);
    });
  }, [router]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    setLoading(true);
    try {
      await adminLogin(username, password);
      router.replace("/");
    } catch {
      setError("Invalid username or password.");
    } finally {
      setLoading(false);
    }
  }

  if (checking) {
    return (
      <main style={styles.page}>
        <span style={{ color: "var(--text-muted)", fontSize: 13 }}>Loading…</span>
      </main>
    );
  }

  return (
    <main style={styles.page}>
      <form onSubmit={onSubmit} className="card" style={styles.card}>
        <h1 style={styles.title}>NimJump Admin</h1>
        <p style={styles.subtitle}>Sign in to continue</p>

        <label style={styles.label}>
          Username
          <input
            autoFocus
            value={username}
            onChange={e => setUsername(e.target.value)}
            style={styles.input}
            autoComplete="username"
          />
        </label>

        <label style={styles.label}>
          Password
          <input
            type="password"
            value={password}
            onChange={e => setPassword(e.target.value)}
            style={styles.input}
            autoComplete="current-password"
          />
        </label>

        {error && <div style={styles.error}>{error}</div>}

        <button
          type="submit"
          className="btn btn-blue"
          disabled={loading || !username || !password}
          style={styles.submit}
        >
          {loading ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </main>
  );
}

const styles: Record<string, React.CSSProperties> = {
  page: {
    minHeight: "100vh",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    padding: 16,
  },
  card: {
    width: "100%",
    maxWidth: 340,
    padding: 28,
    display: "flex",
    flexDirection: "column",
    gap: 14,
  },
  title: { fontSize: 18, fontWeight: 700 },
  subtitle: { fontSize: 13, color: "var(--text-muted)", marginTop: -8, marginBottom: 4 },
  label: {
    display: "flex",
    flexDirection: "column",
    gap: 6,
    fontSize: 12,
    color: "var(--text-muted)",
  },
  input: {
    background: "var(--surface2)",
    border: "1px solid var(--border)",
    borderRadius: 6,
    padding: "8px 10px",
    color: "var(--text)",
    fontSize: 14,
  },
  error: {
    fontSize: 12,
    color: "var(--red)",
    background: "#2d1216",
    border: "1px solid #4d1e20",
    borderRadius: 6,
    padding: "8px 10px",
  },
  submit: {
    marginTop: 4,
    padding: "9px 12px",
    fontSize: 14,
    fontWeight: 600,
  },
};

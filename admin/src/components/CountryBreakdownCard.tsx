"use client";

import { useEffect, useState } from "react";
import { fetchCountryBreakdown, type CountryBreakdownEntry } from "@/lib/api";

// "Where are our players actually connecting from" — aggregated from each
// player's most-recently-seen IP, geolocated via backend/game/player_ip.go's
// GetIPGeo (cached forever per IP, so this is cheap after the first load).
// Mirrors DeviceBreakdownCard's shape/pattern exactly, just for geography.
function flagEmoji(countryCode: string): string {
  if (!countryCode || countryCode.length !== 2) return "🏳️";
  const codePoints = [...countryCode.toUpperCase()].map(c => 0x1f1e6 - 65 + c.charCodeAt(0));
  return String.fromCodePoint(...codePoints);
}

export default function CountryBreakdownCard() {
  const [entries, setEntries] = useState<CountryBreakdownEntry[] | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    fetchCountryBreakdown()
      .then(setEntries)
      .catch((e) => setError(String(e instanceof Error ? e.message : e)));
  }, []);

  if (error) return null; // non-fatal — just don't show the card
  if (!entries) return null;

  const total = entries.reduce((sum, e) => sum + e.count, 0);
  if (total === 0) {
    return (
      <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 10, padding: 16, marginBottom: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, color: "#e2e8f0", marginBottom: 6 }}>Countries</div>
        <div style={{ color: "#64748b", fontSize: 12 }}>
          No country data yet — populates as players sign in.
        </div>
      </div>
    );
  }

  return (
    <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 10, padding: 16, marginBottom: 16 }}>
      <div style={{ fontWeight: 600, fontSize: 13, color: "#e2e8f0", marginBottom: 10 }}>
        Countries <span style={{ color: "#64748b", fontWeight: 400 }}>({total} players)</span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {entries.map((e) => {
          const pct = total > 0 ? Math.round((e.count / total) * 100) : 0;
          return (
            <div key={e.country_code} style={{ display: "flex", alignItems: "center", gap: 10 }}>
              <span style={{ fontSize: 12, color: "#e2e8f0", minWidth: 130, display: "flex", alignItems: "center", gap: 6 }}>
                <span>{flagEmoji(e.country_code)}</span>
                <span>{e.country_name}</span>
              </span>
              <div style={{ flex: 1, height: 8, borderRadius: 4, background: "#1e293b", overflow: "hidden" }}>
                <div style={{ width: `${pct}%`, height: "100%", background: "#22c55e", borderRadius: 4 }} />
              </div>
              <span style={{ fontSize: 12, color: "#94a3b8", minWidth: 60, textAlign: "right" }}>
                {e.count} ({pct}%)
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

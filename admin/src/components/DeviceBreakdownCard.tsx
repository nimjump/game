"use client";

import { useEffect, useState } from "react";
import { fetchDeviceBreakdown, type DeviceBreakdownEntry } from "@/lib/api";

// "What devices are our players actually on" — aggregated from device info
// captured at wallet-auth verify time (see backend/game/device.go). Every
// real player passes through login, so this is a much more representative
// sample than the per-error device list in the Logs tab (which only covers
// players who happened to hit a bug).
export default function DeviceBreakdownCard() {
  const [entries, setEntries] = useState<DeviceBreakdownEntry[] | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    fetchDeviceBreakdown()
      .then(setEntries)
      .catch((e) => setError(String(e instanceof Error ? e.message : e)));
  }, []);

  if (error) return null; // non-fatal — just don't show the card
  if (!entries) return null;

  const total = entries.reduce((sum, e) => sum + e.count, 0);
  if (total === 0) {
    return (
      <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 10, padding: 16, marginBottom: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, color: "#e2e8f0", marginBottom: 6 }}>Device breakdown</div>
        <div style={{ color: "#64748b", fontSize: 12 }}>
          No device data yet — populates as players sign in (needs the new backend build live).
        </div>
      </div>
    );
  }

  return (
    <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 10, padding: 16, marginBottom: 16 }}>
      <div style={{ fontWeight: 600, fontSize: 13, color: "#e2e8f0", marginBottom: 10 }}>
        Device breakdown <span style={{ color: "#64748b", fontWeight: 400 }}>({total} players)</span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {entries.map((e) => {
          const pct = total > 0 ? Math.round((e.count / total) * 100) : 0;
          return (
            <div key={e.platform} style={{ display: "flex", alignItems: "center", gap: 10 }}>
              <span style={{ fontSize: 12, color: "#e2e8f0", minWidth: 110 }}>{e.platform}</span>
              <div style={{ flex: 1, height: 8, borderRadius: 4, background: "#1e293b", overflow: "hidden" }}>
                <div style={{ width: `${pct}%`, height: "100%", background: "#6366f1", borderRadius: 4 }} />
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

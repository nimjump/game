"use client";
import type { Overview } from "@/lib/api";

type Tab = "overview" | "active" | "completed" | "flagged" | "all" | "failed_replays" | "logs";

interface Props {
  ov: Overview;
  activeTab: Tab;
  onTabChange: (t: Tab) => void;
}

export default function StatCards({ ov, activeTab, onTabChange }: Props) {
  const cards: { label: string; value: number; color: string; tab: Tab }[] = [
    { label: "Total",            value: ov.counts.total,              color: "var(--text)",   tab: "all" },
    { label: "🎮 Active",        value: ov.counts.active,             color: "var(--green)",  tab: "active" },
    { label: "✅ Completed",     value: ov.counts.completed,          color: "var(--blue)",   tab: "completed" },
    { label: "🚩 Flagged",       value: ov.counts.flagged,            color: "var(--red)",    tab: "flagged" },
    { label: "⚠ Replay Failed",  value: ov.counts.replay_failed ?? 0, color: "var(--yellow)", tab: "failed_replays" },
  ];

  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(5,1fr)", gap: 10, marginBottom: 20 }}>
      {cards.map(c => (
        <div key={c.label} className="card"
          style={{
            padding: "14px 16px", cursor: "pointer",
            borderColor: activeTab === c.tab ? "var(--blue)" : undefined,
          }}
          onClick={() => onTabChange(c.tab)}
        >
          <div style={{ color: "var(--text-muted)", fontSize: 11, marginBottom: 4 }}>{c.label}</div>
          <div style={{ fontSize: 26, fontWeight: 700, color: c.color }}>{c.value}</div>
        </div>
      ))}
    </div>
  );
}

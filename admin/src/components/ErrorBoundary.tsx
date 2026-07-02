"use client";
import { Component, type ReactNode } from "react";

// ErrorBoundary — catches render exceptions in whatever tab is currently
// mounted so ONE broken tab (e.g. a bad/unexpected API response shape)
// shows an inline error instead of throwing all the way up and blanking
// the entire admin page (Next.js App Router has no default recovery for
// an uncaught render exception without a boundary in the tree).
//
// Give this a `key={tab}` from the parent so switching tabs always
// re-mounts a fresh boundary — otherwise, once tripped, it would keep
// showing the fallback forever even after navigating to a different,
// perfectly healthy tab.
interface Props {
  children: ReactNode;
}
interface State {
  error: Error | null;
}

export default class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: { componentStack: string }) {
    console.error("[AdminPanel] tab crashed:", error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      return (
        <div style={{ padding: 24, color: "var(--red)", fontSize: 13 }}>
          <div style={{ fontWeight: 600, marginBottom: 6 }}>
            This tab hit an error and couldn&apos;t render.
          </div>
          <div style={{ color: "var(--text-muted)", fontFamily: "monospace", fontSize: 12 }}>
            {this.state.error.message}
          </div>
          <div style={{ marginTop: 8, color: "var(--text-muted)" }}>
            Try switching to another tab and back, or refresh the page.
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}

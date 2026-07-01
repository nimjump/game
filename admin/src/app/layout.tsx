import type { Metadata } from "next"
import "./globals.css"

export const metadata: Metadata = {
  title: "NimJump Admin",
  description: "NimJump admin panel",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{ minHeight: "100vh" }}>{children}</body>
    </html>
  )
}
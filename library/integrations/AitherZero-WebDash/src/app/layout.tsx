import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import { Toaster } from "sonner";
import "./globals.css";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
  display: "swap",
});

const jetbrainsMono = JetBrains_Mono({
  variable: "--font-jetbrains-mono",
  subsets: ["latin"],
  display: "swap",
});

export const metadata: Metadata = {
  title: "AitherZero | CI/CD Control Platform",
  description: "Sophisticated CI/CD orchestration and AI agent management platform",
  icons: {
    icon: "/favicon.ico",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="dark">
      <body
        className={`${inter.variable} ${jetbrainsMono.variable} font-sans antialiased min-h-screen bg-background`}
      >
        {children}
        <Toaster 
          position="top-right"
          toastOptions={{
            style: {
              background: 'oklch(0.20 0.03 250)',
              border: '1px solid oklch(0.30 0.03 250)',
              color: 'oklch(0.95 0 0)',
            },
          }}
        />
      </body>
    </html>
  );
}

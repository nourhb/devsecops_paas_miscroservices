import { NextResponse } from "next/server";

export async function GET() {
  const grafanaBase = process.env.GRAFANA_URL ?? "";

  return NextResponse.json({
    grafanaUrl: grafanaBase,
  });
}


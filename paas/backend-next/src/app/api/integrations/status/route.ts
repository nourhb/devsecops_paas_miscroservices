import { NextResponse } from 'next/server';
import { verifyAll } from '../../../../lib/services/integrations';

export async function GET() {
  const results = await verifyAll();
  return NextResponse.json(results);
}

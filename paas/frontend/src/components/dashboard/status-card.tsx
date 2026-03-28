import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

interface StatusCardProps {
  title: string;
  value: string | number;
  helper?: string;
}

export function StatusCard({ title, value, helper }: StatusCardProps) {
  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-sm text-muted">{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <p className="text-2xl font-semibold">{value}</p>
        {helper ? <p className="mt-1 text-xs text-muted">{helper}</p> : null}
      </CardContent>
    </Card>
  );
}

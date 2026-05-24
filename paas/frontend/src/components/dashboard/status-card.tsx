import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
interface StatusCardProps {
    title: string;
    value: string | number;
}
export function StatusCard({ title, value }: StatusCardProps) {
    return (<Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-sm text-muted">{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <p className="text-2xl font-semibold">{value}</p>
      </CardContent>
    </Card>);
}

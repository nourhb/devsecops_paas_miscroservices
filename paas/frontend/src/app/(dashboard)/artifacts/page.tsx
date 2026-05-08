"use client";
import { useEffect, useState } from "react";
import { Download, Package, RefreshCw } from "lucide-react";
import { artifactApi } from "@/lib/api";
import type { ArtifactListResponse, ArtifactRecord } from "@/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
function formatDate(value: string): string {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "\u2014" : date.toLocaleString();
}
export default function ArtifactsPage() {
    const [artifacts, setArtifacts] = useState<ArtifactRecord[]>([]);
    const [latestArtifact, setLatestArtifact] = useState<ArtifactRecord | null>(null);
    const [loading, setLoading] = useState(true);
    const [refreshing, setRefreshing] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const loadArtifacts = async (background = false) => {
        if (background) {
            setRefreshing(true);
        }
        else {
            setLoading(true);
        }
        setError(null);
        try {
            const response: ArtifactListResponse = await artifactApi.list();
            setArtifacts(response.artifacts);
            setLatestArtifact(response.latestArtifact);
        }
        catch (err) {
            const message = err instanceof Error ? err.message : "Could not load artifacts.";
            setError(message);
        }
        finally {
            setLoading(false);
            setRefreshing(false);
        }
    };
    useEffect(() => {
        void loadArtifacts();
    }, []);
    return (<div className="mx-auto max-w-6xl space-y-8">
            <header className="flex flex-col gap-4 border-b border-border/60 pb-8 sm:flex-row sm:items-end sm:justify-between">
                <div className="space-y-1">
                    <p className="text-xs font-medium text-muted">Build Outputs</p>
                    <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Image artifacts</h1>
                </div>
                <Button variant="outline" onClick={() => void loadArtifacts(true)} disabled={refreshing || loading}>
                    <RefreshCw className={`mr-2 h-4 w-4 ${refreshing ? "animate-spin" : ""}`}/>
                    {refreshing ? "Refreshing..." : "Refresh"}
                </Button>
            </header>

            <section className="grid gap-4 md:grid-cols-2">
                <Card>
                    <CardHeader>
                        <CardTitle className="flex items-center gap-2 text-base">
                            <Package className="h-5 w-5 text-primary"/>
                            Latest image
                        </CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-3 text-sm">
                        <div>
                            <p className="text-xs uppercase tracking-wide text-muted">Name</p>
                            <p className="mt-1 font-medium">{latestArtifact?.name || "\u2014"}</p>
                        </div>
                        <div>
                            <p className="text-xs uppercase tracking-wide text-muted">Version</p>
                            <p className="mt-1">{latestArtifact?.version || "\u2014"}</p>
                        </div>
                        <div>
                            <p className="text-xs uppercase tracking-wide text-muted">Stored at</p>
                            <p className="mt-1">{latestArtifact ? formatDate(latestArtifact.createdAt) : "\u2014"}</p>
                        </div>
                    </CardContent>
                </Card>

                <Card>
                    <CardHeader>
                        <CardTitle className="text-base">Registry summary</CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-3 text-sm">
                        <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
                            <span className="text-muted">Image artifacts</span>
                            <span className="font-semibold">{artifacts.length}</span>
                        </div>
                        <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
                            <span className="text-muted">Latest version</span>
                            <span className="font-semibold">{latestArtifact?.version || "\u2014"}</span>
                        </div>
                        <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
                            <span className="text-muted">Repository</span>
                            <span className="font-semibold">{latestArtifact?.repository || "\u2014"}</span>
                        </div>
                    </CardContent>
                </Card>
            </section>

            <Card>
                <CardHeader>
                    <CardTitle className="text-base">Image artifacts</CardTitle>
                </CardHeader>
                <CardContent className="px-0 pb-0">
                    {loading ? (<p className="px-6 pb-6 text-sm text-muted">Loading artifacts...</p>) : error ? (<p className="px-6 pb-6 text-sm text-danger">{error}</p>) : artifacts.length === 0 ? (<p className="px-6 pb-6 text-sm text-muted">No image artifacts found yet. Run a build or deploy first.</p>) : (<Table>
                            <TableHeader>
                                <TableRow className="hover:bg-transparent">
                                    <TableHead className="pl-6">Name</TableHead>
                                    <TableHead>Version</TableHead>
                                    <TableHead>Size</TableHead>
                                    <TableHead>Date</TableHead>
                                    <TableHead>Status</TableHead>
                                    <TableHead className="pr-6 text-right">Link</TableHead>
                                </TableRow>
                            </TableHeader>
                            <TableBody>
                                {artifacts.map((artifact) => (<TableRow key={`${artifact.path}-${artifact.version}`}>
                                        <TableCell className="pl-6 font-medium">{artifact.name}</TableCell>
                                        <TableCell>{artifact.version}</TableCell>
                                        <TableCell>{artifact.size}</TableCell>
                                        <TableCell>{formatDate(artifact.createdAt)}</TableCell>
                                        <TableCell>
                                            <Badge variant="success">{artifact.status}</Badge>
                                        </TableCell>
                                        <TableCell className="pr-6 text-right">
                                            {artifact.downloadUrl ? (<Button variant="outline" size="sm" asChild>
                                                    <a href={artifact.downloadUrl} target="_blank" rel="noopener noreferrer">
                                                        <Download className="mr-2 h-4 w-4"/>
                                                        Open
                                                    </a>
                                                </Button>) : (<span className="text-sm text-muted">—</span>)}
                                        </TableCell>
                                    </TableRow>))}
                            </TableBody>
                        </Table>)}
                </CardContent>
            </Card>
        </div>);
}

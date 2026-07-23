export type HeadlessBrowserStatus =
  | "starting"
  | "running"
  | "degraded"
  | "reconfiguring"
  | "stopping"
  | "stopped"
  | "failed";

export type HeadlessBrowserAuthMode =
  | "chatgpt_oauth"
  | "pure_api"
  | "mixed_api"
  | "not_authenticated";

export type HeadlessBrowserState = {
  instanceId: string;
  status: HeadlessBrowserStatus;
  message: string;
  startedAtMs: number;
  tmuxSession: string;
  accessPort: number | null;
  authMode: HeadlessBrowserAuthMode;
  gatewayPid: number | null;
  relayPid: number | null;
  electronPid: number | null;
  ownedPids: number[];
  failureCode: string | null;
};

export function parseHeadlessBrowserPort(value: string): number | undefined {
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  const port = Number(trimmed);
  if (!Number.isInteger(port) || port < 49_152 || port > 65_535) {
    throw new Error("Browser port must be an integer between 49152 and 65535.");
  }
  return port;
}

export function headlessBrowserIsActive(state: HeadlessBrowserState | null): boolean {
  return Boolean(
    state
      && ["starting", "running", "degraded", "reconfiguring", "stopping"].includes(
        state.status,
      ),
  );
}

export function headlessBrowserSummaryPid(state: HeadlessBrowserState | null): number | null {
  return state?.electronPid ?? state?.gatewayPid ?? state?.ownedPids[0] ?? null;
}

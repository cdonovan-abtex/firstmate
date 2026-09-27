import { spawnSync } from "node:child_process";

export type MonitoringPaths = { root: string; home: string; state: string; config: string };
export type MonitoringStopVerdict = {
  status: "none" | "active" | "resumed" | "malformed";
  detail: string;
};
export type WatchReadiness = "ready" | "stopped" | "failed";
export type WatchArmResult =
  | { kind: "starting" | "stopped"; ok: true; message: string }
  | { kind: "failed"; ok: false; message: string };

export function monitoringStopVerdict(paths: MonitoringPaths): MonitoringStopVerdict {
  const result = spawnSync("bash", [`${paths.root}/bin/fm-monitoring-stop.sh`, "status", "--json"], {
    cwd: paths.root,
    encoding: "utf8",
    env: {
      ...process.env,
      FM_HOME: paths.home,
      FM_ROOT_OVERRIDE: paths.root,
      FM_STATE_OVERRIDE: paths.state,
      FM_CONFIG_OVERRIDE: paths.config,
    },
  });
  if (result.status !== 0) {
    return {
      status: "malformed",
      detail: String(result.stderr || "").trim() || `monitoring-stop status helper exited ${result.status ?? "without status"}`,
    };
  }
  try {
    const parsed = JSON.parse(String(result.stdout || ""));
    if (!["none", "active", "resumed", "malformed"].includes(parsed?.status)) {
      throw new Error("status is not recognized");
    }
    return { status: parsed.status, detail: typeof parsed.detail === "string" ? parsed.detail : "" };
  } catch (error) {
    return {
      status: "malformed",
      detail: `monitoring-stop status helper returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

export function monitoringStopped(paths: MonitoringPaths): boolean {
  const { status } = monitoringStopVerdict(paths);
  return status === "active" || status === "malformed";
}

export function watcherCloseResult(paths: MonitoringPaths, code: number | null): WatchReadiness {
  return code === 3 || monitoringStopped(paths) ? "stopped" : "failed";
}

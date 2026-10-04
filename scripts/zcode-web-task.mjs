import { randomUUID } from "node:crypto";
import { realpath, mkdir, readFile } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

function fail(message) {
  console.error(`zcode-web-task: ${message}`);
  process.exit(64);
}

const args = process.argv.slice(2);
if (!["start", "resume"].includes(args[0]) || args.length !== (args[0] === "start" ? 2 : 3)) {
  fail("usage: zcode-web-task start <workspace-name> | resume <task-id> <workspace-name>");
}
const operation = args[0];
const taskId = operation === "resume" ? args[1] : "";
const workspaceName = operation === "resume" ? args[2] : args[1];
const clientPath = process.env.ZCODE_WEB_CLIENT;
const port = process.env.PORT || "8080";
let token = process.env.ZCODE_SERVER_AUTH_TOKEN || process.env.AGENT_WEB_TOKEN;
if (!token) {
  const envFile = process.env.AGENT_SERVICE_ENV_FILE || "/run/agent-service.env";
  const values = new Map();
  const content = await readFile(envFile, "utf8").catch(() => "");
  for (const line of content.split(/\r?\n/)) {
    if (!line) continue;
    const separator = line.indexOf("=");
    if (separator < 1) fail("the authenticated ZCode Web service is unavailable");
    const name = line.slice(0, separator);
    if (!["AGENT_WEB_TOKEN", "ZAI_SUBSCRIPTION_KEY"].includes(name) || values.has(name)) {
      fail("the authenticated ZCode Web service is unavailable");
    }
    values.set(name, line.slice(separator + 1));
  }
  token = values.get("AGENT_WEB_TOKEN");
}
if (!token || !clientPath) fail("the authenticated ZCode Web service is unavailable");

const base = await realpath(resolve(process.env.HOME || "/home/agent", "work"));
if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/.test(workspaceName)) fail("invalid workspace name");
if (operation === "resume" && !/^sess_[0-9a-f-]+$/i.test(taskId)) fail("invalid task id");
const requested = resolve(base, workspaceName);
if (operation === "start") await mkdir(requested, { recursive: true });
const workspacePath = await realpath(requested);
const workspaceRelative = relative(base, workspacePath);
if (!workspaceRelative || workspaceRelative.startsWith("..") || isAbsolute(workspaceRelative)) {
  fail("workspace must be inside the persistent work directory");
}
let prompt = "";
for await (const chunk of process.stdin) {
  prompt += chunk;
  if (Buffer.byteLength(prompt) > 16384) fail("prompt exceeds 16384 bytes");
}
if (!prompt.trim()) fail("prompt input is empty");

const { connectViaWebSocket } = await import(pathToFileURL(clientPath).href);
let socket;
let cancelled = false;
let taskService;
let activeTask = taskId;
try {
  const api = await connectViaWebSocket(
    `ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(token)}`,
    { onOpenSocket: (value) => (socket = value) },
  );
  taskService = api.zcodeTaskService;
  const view = await api.modelSelectionService.getView();
  const provider = view.providers.find(
    (item) => item.templateId === "zai-api" && item.providerName === "nix-agent-sandbox",
  );
  const modelId = process.env.ZCODE_DEFAULT_MODEL || "GLM-5.3-Flash";
  const model = provider?.models.find((item) => item.modelId === modelId);
  const reasoning = model?.config?.optionSpecs?.reasoningLevel?.values;
  if (!provider || !model || !Array.isArray(reasoning) || reasoning.length === 0) {
    fail("the native Z.ai model is not configured");
  }
  const modelSelection = {
    providerId: provider.providerId,
    modelId: model.modelId,
    options: { reasoningLevel: reasoning.at(-1) },
  };

  if (operation === "start") {
    const created = await taskService.createTask({
      workspacePath,
      mode: "yolo",
      modelSelection,
      v4Create: true,
    });
    activeTask = created.taskId;
  } else {
    const resumed = await taskService.resumeTask({
      taskId: activeTask,
      workspacePath,
      mode: "yolo",
    });
    if (resumed.taskId !== activeTask) fail("native task resume returned a different task id");
  }

  console.log(JSON.stringify({ event: "created", task_id: activeTask, workspace: workspaceRelative }));
  const inputId = randomUUID();
  let outcome;
  let readyReason;
  const subscriptions = [];
  const terminalAndReady = new Promise((resolveDone) => {
    const maybeDone = () => {
      if (outcome && readyReason) resolveDone();
    };
    subscriptions.push(
      taskService.onDynamicTaskTerminalOutcome(activeTask)((event) => {
        if (event.inputId !== inputId) return;
        outcome = event.outcome;
        maybeDone();
      }),
    );
    subscriptions.push(
      taskService.onDynamicTaskReady(activeTask)((event) => {
        readyReason = event.reason;
        maybeDone();
      }),
    );
  });
  const interrupt = async () => {
    cancelled = true;
    try {
      await taskService.stopGeneration({ taskId: activeTask, workspacePath });
    } catch {
      // The caller's durable claim records interruption independently.
    }
  };
  process.once("SIGTERM", interrupt);
  process.once("SIGINT", interrupt);

  await taskService.sendPrompt({
    taskId: activeTask,
    traceId: inputId,
    content: prompt,
    clientMode: "web-remote-replayable",
    modelSelection,
  });
  await terminalAndReady;
  for (const subscription of subscriptions) {
    if (typeof subscription === "function") subscription();
    else subscription.dispose();
  }
  console.log(JSON.stringify({
    event: "terminal",
    task_id: activeTask,
    input_id: inputId,
    outcome: cancelled ? "cancelled" : outcome,
    ready_reason: readyReason,
  }));
  if (!cancelled && outcome === "succeeded") process.exitCode = 0;
  else process.exitCode = 1;
} catch {
  console.error(JSON.stringify({ event: "error", task_id: activeTask || null }));
  process.exitCode = 1;
} finally {
  socket?.close();
}

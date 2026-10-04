import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const token = process.env.ZCODE_SERVER_AUTH_TOKEN;
const apiKey = process.env.ZAI_SUBSCRIPTION_KEY;
const port = process.env.PORT || "8080";
const clientPath = process.env.ZCODE_WEB_CLIENT;
const server = spawn("zcode-web", [], { stdio: "inherit", env: process.env });
const serverExit = new Promise((resolve) => server.once("exit", resolve));
let stopping = false;

function stop(signal = "SIGTERM") {
  if (stopping) return;
  stopping = true;
  if (server.exitCode === null) server.kill(signal);
}

process.on("SIGTERM", () => stop("SIGTERM"));
process.on("SIGINT", () => stop("SIGINT"));

try {
  if (!token || !apiKey || !clientPath) throw new Error();

  const origin = `http://127.0.0.1:${port}`;
  let ready = false;
  for (let attempt = 0; attempt < 60 && !ready; attempt += 1) {
    if (server.exitCode !== null) throw new Error();
    try {
      const response = await fetch(
        `${origin}/api/server-info?token=${encodeURIComponent(token)}`,
        { signal: AbortSignal.timeout(1000) },
      );
      ready = response.ok;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  if (!ready) throw new Error();

  const { connectViaWebSocket } = await import(pathToFileURL(clientPath).href);
  let socket;
  const services = await connectViaWebSocket(
    `ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(token)}`,
    { onOpenSocket: (value) => (socket = value) },
  );
  try {
    const settings = services.providerSettingsService;
    const view = await settings.getView();
    const template = view.providerTemplates.find((item) => item.templateId === "zai-api");
    if (!template?.config?.access?.type) throw new Error();

    const initialConfig = {
      access: { type: template.config.access.type, apiKey },
    };
    const provider = view.providers.find(
      (item) => item.templateId === "zai-api" && item.providerName === "nix-agent-sandbox",
    );
    if (provider) {
      await settings.savePersonalProviderOverlay(provider.providerId, initialConfig);
    } else {
      await settings.createPersonalProvider({
        templateId: "zai-api",
        providerName: "nix-agent-sandbox",
        locale: "en-US",
        initialConfig,
      });
    }

    const modelView = await services.modelSelectionService.getView();
    const configured = modelView.providers.find(
      (item) => item.templateId === "zai-api" && item.providerName === "nix-agent-sandbox",
    );
    const modelId = process.env.ZCODE_DEFAULT_MODEL || "GLM-5.3-Flash";
    if (!configured?.models.some((model) => model.modelId === modelId)) throw new Error();
  } finally {
    socket?.close();
  }

  console.log("zcode-web-supervisor: native Z.ai provider ready");
  const code = await serverExit;
  process.exitCode = typeof code === "number" ? code : 1;
} catch {
  console.error("zcode-web-supervisor: server or native provider setup failed");
  stop();
  if (server.exitCode === null) await serverExit;
  process.exitCode = 1;
}

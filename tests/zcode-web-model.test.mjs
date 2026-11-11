import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const taskPath = join(repoRoot, "scripts", "zcode-web-task.mjs");
const supervisorPath = join(repoRoot, "scripts", "zcode-web-supervisor.mjs");
const scriptPath = join(repoRoot, "scripts");

async function filesUnder(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? filesUnder(path) : [path];
  }));
  return nested.flat();
}

test("web task refuses when ZAI_MODEL is absent from its environment and service file", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "zcode-web-model-missing-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const env = {
    PATH: process.env.PATH ?? "",
    HOME: home,
    AGENT_SERVICE_ENV_FILE: join(home, "service.env"),
    ZCODE_WEB_CLIENT: join(home, "unused-client.mjs"),
    ZCODE_SERVER_AUTH_TOKEN: "placeholder-token",
  };

  const result = spawnSync(process.execPath, [taskPath, "start", "workspace-one"], {
    encoding: "utf8",
    env,
    input: "Review the change",
  });

  assert.equal(result.status, 64);
  assert.equal(result.stderr, "zcode-web-task: ZAI_MODEL is missing\n");
  assert.equal(result.stdout, "");
});

test("web task loads and selects ZAI_MODEL from the service environment file", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "zcode-web-model-set-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  await mkdir(join(home, "work"), { recursive: true });
  const serviceEnvPath = join(home, "service.env");
  const modelId = `fixture-${randomUUID()}`;
  await writeFile(serviceEnvPath, `AGENT_WEB_TOKEN=placeholder-token\nZAI_MODEL=${modelId}\n`);
  const clientPath = join(home, "client.mjs");
  const capturePath = join(home, "model-selection.json");
  await writeFile(clientPath, `
import { writeFile } from "node:fs/promises";

export async function connectViaWebSocket(_url, { onOpenSocket }) {
  onOpenSocket({ close() {} });
  let onTerminal;
  let onReady;
  const taskService = {
    async createTask({ modelSelection }) {
      await writeFile(process.env.CAPTURE_FILE, JSON.stringify(modelSelection));
      return { taskId: "sess_01234567-89ab-cdef-0123-456789abcdef" };
    },
    onDynamicTaskTerminalOutcome() {
      return (callback) => {
        onTerminal = callback;
        return () => {};
      };
    },
    onDynamicTaskReady() {
      return (callback) => {
        onReady = callback;
        return () => {};
      };
    },
    async sendPrompt({ traceId }) {
      onTerminal({ inputId: traceId, outcome: "succeeded" });
      onReady({ reason: "completed" });
    },
  };
  return {
    zcodeTaskService: taskService,
    modelSelectionService: {
      async getView() {
        return {
          providers: [{
            templateId: "zai-api",
            providerName: "nix-agent-sandbox",
            providerId: "placeholder-provider-id",
            models: [{
              modelId: process.env.ZAI_MODEL,
              config: { optionSpecs: { reasoningLevel: { values: ["low", "high"] } } },
            }],
          }],
        };
      },
    },
  };
}
`);
  const env = {
    PATH: process.env.PATH ?? "",
    HOME: home,
    AGENT_SERVICE_ENV_FILE: serviceEnvPath,
    ZCODE_WEB_CLIENT: clientPath,
    CAPTURE_FILE: capturePath,
  };

  const result = spawnSync(process.execPath, [taskPath, "start", "workspace-one"], {
    encoding: "utf8",
    env,
    input: "Review the change",
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.split(/\r?\n/).filter((line) => line === `model=${modelId}`).length, 1);
  assert.deepEqual(JSON.parse(await readFile(capturePath, "utf8")), {
    providerId: "placeholder-provider-id",
    modelId,
    options: { reasoningLevel: "high" },
  });
});

test("web supervisor resolves the shared model module before validating its environment", () => {
  const result = spawnSync(process.execPath, [supervisorPath], {
    encoding: "utf8",
    env: { PATH: process.env.PATH ?? "" },
  });

  assert.equal(result.status, 65);
  assert.equal(result.stderr, "zcode-web-supervisor: ZAI_MODEL is missing\n");
});

test("scripts contain no literal GLM model id or alternate model setting", async () => {
  const files = await filesUnder(scriptPath);
  for (const path of files) {
    const contents = await readFile(path, "utf8");
    assert.doesNotMatch(contents, /glm-[0-9]/i, `${path} contains a literal GLM model id`);
    assert.doesNotMatch(contents, /ZCODE_DEFAULT_MODEL/, `${path} contains an alternate model setting`);
  }
  for (const name of ["zcode-web-task.mjs", "zcode-web-supervisor.mjs"]) {
    const contents = await readFile(join(scriptPath, name), "utf8");
    assert.match(contents, /import \{ getZaiModel \} from "\.\/zcode-model\.mjs";/);
  }
});

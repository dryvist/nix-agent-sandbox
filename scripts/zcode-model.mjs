export function getZaiModel() {
  const modelId = process.env.ZAI_MODEL;
  if (!modelId) throw new Error("ZAI_MODEL is missing");
  if (/[\r\n]/.test(modelId)) throw new Error("ZAI_MODEL must be a single line");
  return modelId;
}

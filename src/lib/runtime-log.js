const fs = require("node:fs/promises");
const path = require("node:path");

function createRuntimeLogger(baseDir) {
  let queue = Promise.resolve();

  async function appendLine(kind, payload) {
    const now = new Date();
    const day = now.toISOString().slice(0, 10);
    const directory = path.join(baseDir, day);
    const filePath = path.join(directory, `${kind}.jsonl`);
    const line = `${JSON.stringify({
      logged_at: now.toISOString(),
      ...payload,
    })}\n`;

    await fs.mkdir(directory, { recursive: true });
    await fs.appendFile(filePath, line, "utf8");
  }

  function enqueue(kind, payload) {
    queue = queue
      .then(() => appendLine(kind, payload))
      .catch((error) => {
        console.error(`Runtime log write failed (${kind})`, error);
      });

    return queue;
  }

  return {
    appendTelemetry(payload) {
      return enqueue("telemetry", payload);
    },
    appendEtaStates(payload) {
      return enqueue("eta-states", payload);
    },
    appendWatchEvent(payload) {
      return enqueue("watch-events", payload);
    },
    flush() {
      return queue;
    },
  };
}

module.exports = {
  createRuntimeLogger,
};

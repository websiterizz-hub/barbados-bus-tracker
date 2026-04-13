const { createApp, createRuntimeContext } = require("../src/server");

let appPromise;

async function getApp() {
  if (!appPromise) {
    appPromise = (async () => {
      console.log("Initializing runtime context...");
      const context = await createRuntimeContext();
      console.log("Creating Express app...");
      return createApp(context);
    })();
  }
  return appPromise;
}

module.exports = async (req, res) => {
  try {
    const app = await getApp();
    return app(req, res);
  } catch (error) {
    console.error("Vercel Function Error:", error);
    res.status(500).json({ error: "Failed to initialize application", details: error.message });
  }
};

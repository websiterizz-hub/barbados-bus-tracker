const fsSync = require("node:fs");
const fs = require("node:fs/promises");
const path = require("node:path");

const cors = require("cors");
const express = require("express");

const {
  captureLiveSnapshot,
  fetchLocatorConfig,
  fetchLocatorStaticData,
  normalizeLiveMessage,
  fetchRouteUpcoming,
  fetchStopUpcoming,
} = require("./lib/locator");
const {
  DEFAULT_NEARBY_LIMIT,
  DEFAULT_NEARBY_RADIUS_METERS,
  buildBootstrapPayload,
  buildDataStore,
  buildNearbyStopResult,
  buildRouteDetail,
  buildStopDetail,
  buildTrackedRouteSummary,
  computeRefreshHintSeconds,
  findNearbyStops,
  normalizeStopUpcoming,
  rankNearbyStop,
  toPublicVehicle,
} = require("./lib/app-data");
const { createLiveTracker } = require("./lib/live-tracker");
const { createRuntimeLogger } = require("./lib/runtime-log");
const {
  fetchRouteDetail,
  fetchRouteFinderHtml,
  extractRouteIndex,
} = require("./lib/transport-board");
const { createStopWatchService } = require("./lib/watch-engine");

const port = Number(process.env.PORT || 3000);
const dataDir = path.resolve(__dirname, "..", "data");
const runtimeDataDir = path.join(dataDir, "runtime");
const webBuildDir = path.resolve(__dirname, "..", "flutter_app", "build", "web");
const webIndexPath = path.join(webBuildDir, "index.html");

async function readCachedJson(fileName) {
  const filePath = path.join(dataDir, fileName);
  const raw = await fs.readFile(filePath, "utf8");
  return JSON.parse(raw);
}

function createTtlCache(ttlMs) {
  const values = new Map();

  return {
    async get(key, loader) {
      const now = Date.now();
      const cached = values.get(key);

      if (cached && cached.expiresAt > now && "value" in cached) {
        return cached.value;
      }

      if (cached?.promise) {
        return cached.promise;
      }

      const promise = Promise.resolve(loader()).then((value) => {
        values.set(key, {
          value,
          expiresAt: Date.now() + ttlMs,
        });
        return value;
      });

      values.set(key, {
        promise,
        expiresAt: now + ttlMs,
      });

      try {
        return await promise;
      } catch (error) {
        values.delete(key);
        throw error;
      }
    },
    clear() {
      values.clear();
    },
  };
}

function parseCoordinate(value, label) {
  const parsed = Number(value);
  if (Number.isNaN(parsed)) {
    const error = new Error(`Invalid ${label}`);
    error.statusCode = 400;
    throw error;
  }
  return parsed;
}

function parseOptionalCoordinate(value) {
  if (value == null || value === "") {
    return undefined;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function parsePositiveNumber(value, fallback) {
  if (value == null) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function createRuntimeContext() {
  const [summary, joinedRoutes, transportBoardRoutes, locatorConfig, locatorPayload] =
    await Promise.all([
      readCachedJson("summary.json"),
      readCachedJson("joined-routes.json"),
      readCachedJson("transport-board-routes.json"),
      fetchLocatorConfig(),
      fetchLocatorStaticData(),
    ]);

  const store = buildDataStore({
    summary,
    joinedRoutes,
    locatorData: locatorPayload.data,
    transportBoardRoutes,
  });
  const bootstrapPayload = buildBootstrapPayload(store);
  const runtimeLogger = createRuntimeLogger(runtimeDataDir);
  const telemetryTracker = createLiveTracker({
    locatorConfig,
    staticIndexes: store.staticIndexes,
    runtimeLogger,
  });
  const stopUpcomingCache = createTtlCache(
    Number(process.env.STOP_UPCOMING_TTL_MS || 1_000),
  );
  const routeUpcomingCache = createTtlCache(
    Number(process.env.ROUTE_UPCOMING_TTL_MS || 2_000),
  );
  const stopWatchService = createStopWatchService({
    store,
    runtimeLogger,
    historyDir: runtimeDataDir,
    getStopUpcoming(stopId) {
      return stopUpcomingCache.get(`stop:${stopId}`, async () =>
        fetchStopUpcoming(stopId, locatorConfig),
      );
    },
    getVehicleState(uid) {
      return telemetryTracker.getVehicleState(uid);
    },
    getNearbyVehicles(lat, lng, radiusMeters, limit = 8) {
      return telemetryTracker.getNearbyVehicles({
        lat,
        lng,
        radiusMeters,
        limit,
      });
    },
  });

  try {
    const seedSnapshot = await captureLiveSnapshot(locatorConfig, {
      maxWaitMs: Number(process.env.SNAPSHOT_MAX_WAIT_MS || 4_000),
      idleMs: Number(process.env.SNAPSHOT_IDLE_MS || 500),
    });
    telemetryTracker.seedSnapshot(seedSnapshot);
  } catch (error) {
    console.error("Failed to seed live tracker from snapshot", error);
  }

  telemetryTracker.start();

  return {
    locatorConfig,
    runtimeLogger,
    store,
    bootstrapPayload,
    telemetryTracker,
    stopWatchService,
    async getStopUpcoming(stopId) {
      return stopUpcomingCache.get(`stop:${stopId}`, async () =>
        fetchStopUpcoming(stopId, locatorConfig),
      );
    },
    async getRouteUpcoming(routeId) {
      return routeUpcomingCache.get(`route:${routeId}`, async () =>
        fetchRouteUpcoming(routeId, locatorConfig),
      );
    },
    async getLiveSnapshot() {
      return telemetryTracker.getSnapshot();
    },
    getVehicleState(uid) {
      return telemetryTracker.getVehicleState(uid);
    },
    getVehiclesForRoute(routeId) {
      return telemetryTracker.getVehiclesForRoute(routeId);
    },
    getNearbyVehicles(lat, lng, radiusMeters, limit = 8) {
      return telemetryTracker.getNearbyVehicles({
        lat,
        lng,
        radiusMeters,
        limit,
      });
    },
    async dispose() {
      await stopWatchService.dispose?.();
      await telemetryTracker.stop();
      await runtimeLogger.flush();
    },
  };
}

function createApp(context) {
  const app = express();
  const hasBuiltWebApp = fsSync.existsSync(webIndexPath);

  app.use(cors());

  app.get("/api/health", (_request, response) => {
    response.json({
      ok: true,
      service: "barbados-bus-data-api",
      now: new Date().toISOString(),
      live_tracker_topic: context.telemetryTracker?.topic || null,
    });
  });

  app.get("/api/transport-board/routes/index", async (_request, response, next) => {
    try {
      const html = await fetchRouteFinderHtml();
      response.json({
        fetchedAt: new Date().toISOString(),
        routes: extractRouteIndex(html),
      });
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/transport-board/routes/:busId", async (request, response, next) => {
    try {
      response.json(await fetchRouteDetail(request.params.busId));
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/locator/config", (_request, response) => {
    response.json(context.locatorConfig);
  });

  app.get("/api/locator/static", (_request, response) => {
    response.json(context.store.locatorData);
  });

  app.get("/api/locator/routes/:routeId/upcoming", async (request, response, next) => {
    try {
      response.json(await context.getRouteUpcoming(request.params.routeId));
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/locator/stops/:stopId/upcoming", async (request, response, next) => {
    try {
      response.json(await context.getStopUpcoming(request.params.stopId));
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/locator/live-snapshot", async (_request, response, next) => {
    try {
      response.json(await context.getLiveSnapshot());
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/datasets/:name", async (request, response, next) => {
    try {
      response.json(await readCachedJson(`${request.params.name}.json`));
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/bootstrap", (_request, response) => {
    response.json(context.bootstrapPayload);
  });

  app.get("/api/nearby", async (request, response, next) => {
    try {
      const lat = parseCoordinate(request.query.lat, "lat");
      const lng = parseCoordinate(request.query.lng, "lng");
      const radiusMeters = parsePositiveNumber(
        request.query.radius_m,
        DEFAULT_NEARBY_RADIUS_METERS,
      );
      const limit = Math.min(
        parsePositiveNumber(request.query.limit, DEFAULT_NEARBY_LIMIT),
        12,
      );
      const nearbyCandidates = findNearbyStops(
        context.store,
        lat,
        lng,
        radiusMeters,
        Math.max(limit * 3, limit),
      );
      const nearbyVehicles = (context.getNearbyVehicles?.(
        lat,
        lng,
        Math.max(radiusMeters * 2, 1500),
        10,
      ) || [])
        .map((vehicle) => ({
          ...toPublicVehicle(vehicle),
          distance_m: vehicle.distance_m,
        }))
        .filter((vehicle) => vehicle.uid != null);
      const stopResults = await Promise.all(
        nearbyCandidates.map(async (stop) => {
          const stopUpcoming = await context.getStopUpcoming(stop.id);
          const arrivals = normalizeStopUpcoming(context.store, stopUpcoming, {
            getVehicleState: context.getVehicleState?.bind(context),
            runtimeLogger: context.runtimeLogger,
            stopId: stop.id,
            logScope: "nearby-stop",
            viewerLat: lat,
            viewerLng: lng,
          });
          const stopVehicles = nearbyVehicles.filter((vehicle) =>
            stop.routes.some((route) => route.live_route_id === vehicle.route_id),
          );
          return buildNearbyStopResult(
            context.store,
            stop,
            arrivals,
            stopVehicles,
          );
        }),
      );
      const rankedStops = stopResults
        .sort((left, right) => {
          const leftRank = rankNearbyStop(left);
          const rightRank = rankNearbyStop(right);
          return (
            leftRank.stateOrder - rightRank.stateOrder ||
            leftRank.etaSeconds - rightRank.etaSeconds ||
            leftRank.distanceMeters - rightRank.distanceMeters
          );
        })
        .slice(0, limit);
      const refreshHintSeconds = computeRefreshHintSeconds({
        arrivals: rankedStops.flatMap((stop) => stop.arrivals),
        vehicles: nearbyVehicles,
      });

      response.json({
        requested_location: {
          lat,
          lng,
        },
        radius_m: radiusMeters,
        limit,
        refresh_hint_seconds: refreshHintSeconds,
        nearby_vehicles: nearbyVehicles,
        stops: rankedStops,
      });
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/stops/:stopId", async (request, response, next) => {
    try {
      const stopId = Number(request.params.stopId);
      const stopUpcoming = await context.getStopUpcoming(stopId);
      const viewerLat = parseOptionalCoordinate(request.query.lat);
      const viewerLng = parseOptionalCoordinate(request.query.lng);
      const stopDetail = buildStopDetail(context.store, stopId, stopUpcoming, {
        getVehicleState: context.getVehicleState?.bind(context),
        getVehiclesForRoute: context.getVehiclesForRoute?.bind(context),
        runtimeLogger: context.runtimeLogger,
        viewerLat,
        viewerLng,
      });

      if (!stopDetail) {
        response.status(404).json({ error: "Stop not found" });
        return;
      }

      response.json(stopDetail);
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/watch/stops/:stopId", async (request, response, next) => {
    try {
      const stopId = Number(request.params.stopId);
      const status = await context.stopWatchService.getStopStatus(stopId);

      if (!status) {
        response.status(404).json({ error: "Watch stop not found" });
        return;
      }

      response.json(status);
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/routes/:routeId", async (request, response, next) => {
    try {
      const routeId = request.params.routeId;
      const route = context.store.routesByKey.get(routeId);

      if (!route) {
        response.status(404).json({ error: "Route not found" });
        return;
      }

      let activeVehicles = [];
      if (route.liveRouteId != null) {
        if (context.getVehiclesForRoute) {
          activeVehicles = context.getVehiclesForRoute(route.liveRouteId);
        } else {
          const snapshot = await context.getLiveSnapshot();
          activeVehicles = snapshot.messages
            .map((message) =>
              normalizeLiveMessage(message, context.store.staticIndexes),
            )
            .filter((message) => message.routeId === route.liveRouteId);
        }
      }

      response.json(buildRouteDetail(context.store, routeId, activeVehicles));
    } catch (error) {
      next(error);
    }
  });

  app.get("/api/tracked", async (_request, response, next) => {
    try {
      const trackedRoutes = Array.from(context.store.routesByKey.values())
        .filter((route) => route.liveRouteId != null)
        .map((route) => ({
          route,
          vehicles: context
            .getVehiclesForRoute(route.liveRouteId)
            .filter((vehicle) => vehicle.confidence_state !== "stale"),
        }))
        .filter((entry) => entry.vehicles.length > 0)
        .map((entry) => buildTrackedRouteSummary(entry.route, entry.vehicles))
        .sort(
          (left, right) =>
            (left.top_state ? { tracking: 0, at_terminal: 1 }[left.top_state] ?? 9 : 9) -
              (right.top_state ? { tracking: 0, at_terminal: 1 }[right.top_state] ?? 9 : 9) ||
            `${left.route_number}|${left.route_name}`.localeCompare(
              `${right.route_number}|${right.route_name}`,
            ),
        );
      const allVehicles = trackedRoutes.flatMap((route) => route.active_vehicles);

      response.json({
        route_count: trackedRoutes.length,
        vehicle_count: allVehicles.length,
        refresh_hint_seconds: computeRefreshHintSeconds({
          vehicles: allVehicles,
        }),
        routes: trackedRoutes,
      });
    } catch (error) {
      next(error);
    }
  });

  if (hasBuiltWebApp) {
    app.use(express.static(webBuildDir));
    app.get(/^(?!\/api(?:\/|$)).*/, (_request, response) => {
      response.sendFile(webIndexPath);
    });
  } else {
    app.get("/", (_request, response) => {
      response.type("text/plain").send(
        [
          "Barbados bus data API",
          "",
          `Routes indexed: ${context.bootstrapPayload.routes.length}`,
          `Stops indexed: ${context.bootstrapPayload.stops.length}`,
          `Live tracker topic: ${context.telemetryTracker?.topic || "n/a"}`,
          "",
          "Build the Flutter web app to serve the rider UI here:",
          "npm run app:build:web",
          "",
          "Useful endpoints:",
          "/api/bootstrap",
          "/api/nearby?lat=13.0975&lng=-59.6130",
          "/api/stops/:stopId",
          "/api/routes/:routeId",
          "/api/locator/live-snapshot",
        ].join("\n"),
      );
    });
  }

  app.use((error, _request, response, _next) => {
    response.status(error.statusCode || 500).json({
      error: error.message,
    });
  });

  return app;
}

async function startServer() {
  const context = await createRuntimeContext();
  const app = createApp(context);
  const server = app.listen(port, () => {
    console.log(`Barbados bus data API listening on http://localhost:${port}`);
  });

  const shutdown = async () => {
    server.close();
    await context.dispose?.();
  };

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);

  return server;
}

if (require.main === module) {
  startServer().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = {
  createApp,
  createRuntimeContext,
  startServer,
};

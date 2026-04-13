const mqtt = require("mqtt");

const { normalizeLiveMessage } = require("./locator");
const { haversineDistanceMeters } = require("./geo");

const HISTORY_WINDOW_MS = 180_000;
const HISTORY_LIMIT = 24;
const MOVEMENT_WINDOW_MS = 90_000;
const MAX_STALE_ROUTE_AGE_SECONDS = 15 * 60;

function roundNumber(value) {
  return value == null ? null : Math.round(value * 100) / 100;
}

function buildTopic(locatorConfig) {
  return `nimbus/locator/${locatorConfig.hash}/#`;
}

function pruneHistory(history, nowMs) {
  while (
    history.length > 0 &&
    (history.length > HISTORY_LIMIT ||
      nowMs - history[0].receivedAtMs > HISTORY_WINDOW_MS)
  ) {
    history.shift();
  }
}

function getWindowStartSample(history, nowMs) {
  const threshold = nowMs - MOVEMENT_WINDOW_MS;
  for (const sample of history) {
    if (sample.receivedAtMs >= threshold) {
      return sample;
    }
  }
  return history[0] || null;
}

function classifyVehicleState({
  fresh,
  originDistanceM,
  speedKph,
  progressIndex,
  movementM90s,
  progressDelta90s,
}) {
  if (!fresh) {
    return {
      confidence_state: "stale",
      confidence_score: 0.18,
      status_text: "Signal lost",
      live_tracking: false,
    };
  }

  if (
    originDistanceM != null &&
    originDistanceM <= 150 &&
    (speedKph ?? 0) < 5 &&
    (progressIndex ?? 0) <= 0.5
  ) {
    return {
      confidence_state: "at_terminal",
      confidence_score: 0.58,
      status_text: "At terminal",
      live_tracking: true,
    };
  }

  if (
    (speedKph ?? 0) >= 8 ||
    movementM90s >= 120 ||
    progressDelta90s >= 0.15 ||
    (originDistanceM != null && originDistanceM > 150) ||
    (progressIndex ?? 0) > 0.5
  ) {
    return {
      confidence_state: "tracking",
      confidence_score:
        (speedKph ?? 0) >= 8 || movementM90s >= 120 || progressDelta90s >= 0.15
          ? 0.9
          : 0.76,
      status_text: "Tracking",
      live_tracking: true,
    };
  }

  return {
    confidence_state: "at_terminal",
    confidence_score: 0.52,
    status_text: "Awaiting departure",
    live_tracking: true,
  };
}

function createLiveTracker({
  locatorConfig,
  staticIndexes,
  runtimeLogger,
  nowFn = Date.now,
}) {
  const vehiclesByUid = new Map();
  const topic = buildTopic(locatorConfig);
  let client = null;
  let started = false;
  let connectedAt = null;

  function buildStateFromMessage(rawMessage) {
    const nowMs = nowFn();
    const normalized = normalizeLiveMessage(rawMessage, staticIndexes, nowMs);
    const uid = normalized.uid;
    const existing = vehiclesByUid.get(uid);
    const history = existing?.history ? [...existing.history] : [];

    history.push({
      routeId: normalized.routeId,
      lat: normalized.position.lat,
      lng: normalized.position.lng,
      speedKph: normalized.position.speedKph,
      progressIndex: normalized.progressIndex,
      receivedAtMs: rawMessage.tm * 1000,
      deviceAtMs: rawMessage.msg.t * 1000,
    });

    pruneHistory(history, nowMs);

    const route =
      normalized.routeId != null
        ? staticIndexes.routesById.get(normalized.routeId) || null
        : null;
    const firstStop =
      route?.s?.length && staticIndexes.stopsById.has(route.s[0])
        ? staticIndexes.stopsById.get(route.s[0])
        : null;
    const originDistanceM = haversineDistanceMeters(
      normalized.position.lat,
      normalized.position.lng,
      firstStop?.p?.[0]?.y ?? null,
      firstStop?.p?.[0]?.x ?? null,
    );
    const windowStart = getWindowStartSample(history, nowMs);
    const movementM90s = haversineDistanceMeters(
      windowStart?.lat ?? null,
      windowStart?.lng ?? null,
      normalized.position.lat,
      normalized.position.lng,
    );
    const progressDelta90s =
      windowStart?.progressIndex != null && normalized.progressIndex != null
        ? Math.max(0, normalized.progressIndex - windowStart.progressIndex)
        : 0;
    const previousSample =
      history.length > 1 ? history[history.length - 2] : windowStart;
    const derived = classifyVehicleState({
      fresh: normalized.fresh,
      originDistanceM,
      speedKph: normalized.position.speedKph,
      progressIndex: normalized.progressIndex,
      movementM90s: movementM90s ?? 0,
      progressDelta90s,
    });
    const moving =
      normalized.fresh &&
      ((normalized.position.speedKph ?? 0) >= 8 || (movementM90s ?? 0) >= 120);

    return {
      latestRaw: rawMessage,
      history,
      state: {
        ...normalized,
        confidence_state: derived.confidence_state,
        confidence_score: derived.confidence_score,
        status_text: derived.status_text,
        live_tracking: derived.live_tracking,
        moving,
        last_seen_seconds: normalized.ageSeconds,
        origin_distance_m: originDistanceM == null ? null : Math.round(originDistanceM),
        movement_m_90s: movementM90s == null ? 0 : Math.round(movementM90s),
        progress_delta_90s: roundNumber(progressDelta90s),
        previous_position:
          previousSample?.lat != null && previousSample?.lng != null
            ? {
                lat: previousSample.lat,
                lng: previousSample.lng,
              }
            : null,
      },
    };
  }

  function ingest(rawMessage, source = "mqtt") {
    if (rawMessage?.id == null || rawMessage?.msg == null) {
      return null;
    }

    const next = buildStateFromMessage(rawMessage);
    vehiclesByUid.set(next.state.uid, next);

    runtimeLogger?.appendTelemetry({
      source,
      uid: next.state.uid,
      route_id: next.state.routeId,
      confidence_state: next.state.confidence_state,
      moving: next.state.moving,
      raw: rawMessage,
    });

    return next.state;
  }

  function seedSnapshot(snapshot) {
    for (const rawMessage of snapshot?.messages || []) {
      ingest(rawMessage, "seed");
    }
  }

  function start() {
    if (started) {
      return;
    }

    started = true;
    client = mqtt.connect("wss://mqtt.flespi.io/", {
      username: locatorConfig.flespiToken,
      password: "",
      clientId: `barbados_bus_tracker_${Date.now()}`,
      clean: true,
      reconnectPeriod: 1500,
    });

    client.on("connect", () => {
      connectedAt = Date.now();
      client.subscribe(topic, (error) => {
        if (error) {
          console.error("MQTT subscribe failed", error);
        }
      });
    });

    client.on("message", (_topic, payload) => {
      try {
        ingest(JSON.parse(payload.toString("utf8")), "mqtt");
      } catch (error) {
        console.error("Failed to process MQTT payload", error);
      }
    });

    client.on("error", (error) => {
      console.error("MQTT client error", error);
    });
  }

  async function stop() {
    if (!client) {
      return;
    }

    await new Promise((resolve) => {
      client.end(true, resolve);
    });
  }

  function getVehicleState(uid) {
    return vehiclesByUid.get(uid)?.state || null;
  }

  function getVehiclesForRoute(routeId) {
    return Array.from(vehiclesByUid.values())
      .map((entry) => entry.state)
      .filter(
        (state) =>
          state.routeId === routeId &&
          state.last_seen_seconds <= MAX_STALE_ROUTE_AGE_SECONDS,
      )
      .sort((left, right) => {
        const stateRank = {
          tracking: 0,
          at_terminal: 1,
          stale: 2,
        };
        return (
          (stateRank[left.confidence_state] ?? 9) -
            (stateRank[right.confidence_state] ?? 9) ||
          left.last_seen_seconds - right.last_seen_seconds
        );
      });
  }

  function getNearbyVehicles({ lat, lng, radiusMeters, limit = 8 }) {
    return Array.from(vehiclesByUid.values())
      .map((entry) => entry.state)
      .filter(
        (state) =>
          state.routeId != null &&
          state.position.lat != null &&
          state.position.lng != null &&
          state.confidence_state !== "stale",
      )
      .map((state) => ({
        ...state,
        distance_m:
          haversineDistanceMeters(
            lat,
            lng,
            state.position.lat,
            state.position.lng,
          ) ?? Number.POSITIVE_INFINITY,
      }))
      .filter((state) => state.distance_m <= radiusMeters)
      .sort((left, right) => {
        const rank = {
          tracking: 0,
          at_terminal: 1,
          stale: 2,
        };
        return (
          (rank[left.confidence_state] ?? 9) -
            (rank[right.confidence_state] ?? 9) ||
          left.distance_m - right.distance_m
        );
      })
      .slice(0, limit)
      .map((state) => ({
        ...state,
        distance_m: Math.round(state.distance_m),
      }));
  }

  function getSnapshot() {
    const vehicles = Array.from(vehiclesByUid.values())
      .map((entry) => entry.latestRaw)
      .sort((left, right) => left.id - right.id);

    return {
      config: {
        hash: locatorConfig.hash,
        name: locatorConfig.name,
        locatorUrl: locatorConfig.locatorUrl,
      },
      topic,
      capturedAt: new Date(nowFn()).toISOString(),
      connectedAt: connectedAt ? new Date(connectedAt).toISOString() : null,
      unitCount: vehicles.length,
      messages: vehicles,
    };
  }

  return {
    getSnapshot,
    getVehicleState,
    getVehiclesForRoute,
    getNearbyVehicles,
    ingest,
    seedSnapshot,
    start,
    stop,
    topic,
  };
}

module.exports = {
  MAX_STALE_ROUTE_AGE_SECONDS,
  createLiveTracker,
};

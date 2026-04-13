const fs = require("node:fs/promises");
const path = require("node:path");

const {
  computeRefreshHintSeconds,
  formatTrackingLabel,
  normalizeStopUpcoming,
  splitArrivalsByConfidence,
  toPublicVehicle,
} = require("./app-data");
const { haversineDistanceMeters } = require("./geo");

const WATCH_POLL_MS = Number(process.env.WATCH_POLL_MS || 2_000);
const WATCH_ENTITY_TTL_MS = 2 * 60 * 60 * 1000;
const WATCH_EVENT_LIMIT = 80;
const OBSERVED_ARRIVAL_RADIUS_M = 120;
const TELEMETRY_PASS_RADIUS_M = 180;
const TELEMETRY_PASS_MIN_MOVEMENT_M = 60;
const UPSTREAM_PASS_RADIUS_M = 140;
const NEAR_STOP_ALERT_RADIUS_M = 450;
const WATCH_LIVE_RADIUS_M = 500;
const HISTORICAL_BIAS_WINDOW_MS = 12 * 60 * 60 * 1000;
const MAX_HISTORICAL_BIAS_SECONDS = 120;
const MAX_APPROACH_ADJUSTMENT_SECONDS = 90;

const ALERT_MILESTONES = [
  { kind: "alert_eta_5m", thresholdSeconds: 5 * 60, label: "5 min" },
  { kind: "alert_eta_10m", thresholdSeconds: 10 * 60, label: "10 min" },
  { kind: "alert_eta_30m", thresholdSeconds: 30 * 60, label: "30 min" },
];

function buildEventId(parts) {
  return parts.filter(Boolean).join(":");
}

function toStopSummary(stop) {
  return {
    id: stop.id,
    name: stop.name,
    description: stop.description,
    lat: stop.lat,
    lng: stop.lng,
    routes: stop.routes,
  };
}

function isoStringFromMs(value) {
  return value == null ? null : new Date(value).toISOString();
}

function buildArrivalKey(arrival) {
  if (arrival.vehicle_uid != null) {
    return `vehicle:${arrival.vehicle_uid}`;
  }

  return `scheduled:${arrival.route_id}:${arrival.scheduled_timestamp ?? "unknown"}`;
}

function trimList(list, limit = WATCH_EVENT_LIMIT) {
  while (list.length > limit) {
    list.pop();
  }
}

function buildRouteHeadline(routeNumber, routeName, fallback = "Bus") {
  const parts = [routeNumber, routeName].filter(Boolean);
  return parts.length > 0 ? parts.join(" ") : fallback;
}

function extractDirectionEndpoints(direction) {
  if (!direction || typeof direction !== "string") {
    return {
      originName: null,
      destinationName: null,
    };
  }

  const towardsMatch = direction.match(/^(.+?)\s+towards\s+(.+)$/i);
  if (towardsMatch) {
    return {
      originName: towardsMatch[1].trim(),
      destinationName: towardsMatch[2].trim(),
    };
  }

  const arrowMatch = direction.match(/^(.+?)\s*->\s*(.+)$/);
  if (arrowMatch) {
    return {
      originName: arrowMatch[1].trim(),
      destinationName: arrowMatch[2].trim(),
    };
  }

  const toMatch = direction.match(/^(.+?)\s+to\s+(.+)$/i);
  if (toMatch) {
    return {
      originName: toMatch[1].trim(),
      destinationName: toMatch[2].trim(),
    };
  }

  return {
    originName: null,
    destinationName: null,
  };
}

function buildTripLabel({
  routeNumber,
  routeName,
  direction,
  destinationName,
  fallback = "Bus",
}) {
  const targetDestination =
    destinationName || extractDirectionEndpoints(direction).destinationName;
  if (routeNumber && targetDestination) {
    return `${routeNumber} toward ${targetDestination}`;
  }
  if (targetDestination) {
    return `Bus toward ${targetDestination}`;
  }
  return buildRouteHeadline(routeNumber, routeName, fallback);
}

function buildRouteEventFields(routeMeta = {}) {
  const derived = extractDirectionEndpoints(routeMeta.direction);
  return {
    route_direction: routeMeta.direction || null,
    origin_name: routeMeta.origin_name || derived.originName,
    destination_name: routeMeta.destination_name || derived.destinationName,
  };
}

function enrichStoredEvent(store, row) {
  const route =
    row?.route_id != null ? store.routesByKey.get(row.route_id) || null : null;
  const routeDirection = row.route_direction || route?.direction || null;
  const fields = buildRouteEventFields({
    direction: routeDirection,
    origin_name: row.origin_name || route?.from || null,
    destination_name: row.destination_name || route?.to || null,
  });

  return {
    ...row,
    ...fields,
  };
}

function buildRouteContext(store, routeId, stopId) {
  const route = store.routesByKey.get(routeId);
  if (!route) {
    return null;
  }

  const stopIndex = route.stops.findIndex((stop) => Number(stop.id) === Number(stopId));
  if (stopIndex < 0) {
    return {
      route,
      stopIndex,
      upstreamStop: null,
    };
  }

  const upstreamStop = stopIndex > 0 ? route.stops[stopIndex - 1] : null;

  return {
    route,
    stopIndex,
    upstreamStop:
      upstreamStop?.lat != null && upstreamStop?.lng != null ? upstreamStop : null,
  };
}

function buildVehicleRouteMeta(store, vehicleState) {
  const route =
    vehicleState?.routeId != null
      ? store.routesByLiveRouteId.get(vehicleState.routeId) || null
      : null;
  const locatorRoute =
    vehicleState?.routeId != null
      ? store.locatorRoutesById.get(vehicleState.routeId) || null
      : null;

  return {
    route_id:
      route?.id ||
      (vehicleState?.routeId != null ? `live-${vehicleState.routeId}` : null),
    route_number:
      route?.routeNumber || vehicleState?.routeNumber || locatorRoute?.n || "",
    route_name:
      route?.routeName ||
      vehicleState?.derivedRouteName ||
      locatorRoute?.d ||
      "",
    direction:
      route?.direction || vehicleState?.routeDirection || locatorRoute?.d || "",
    origin_name: route?.from || null,
    destination_name: route?.to || null,
    live_route_id: route?.liveRouteId ?? vehicleState?.routeId ?? null,
  };
}

function toWatchLiveVehicle(state) {
  const vehicle = toPublicVehicle(state);
  if (!vehicle) {
    return null;
  }

  return {
    ...vehicle,
    distance_m:
      state.distance_m == null ? null : Math.round(state.distance_m),
  };
}

function buildAccuracyBucket(kind, evaluations) {
  const relevant = evaluations.filter((evaluation) => evaluation.kind === kind);
  const evaluated = relevant.filter(
    (evaluation) => typeof evaluation.error_seconds === "number",
  );
  const avgAbsErrorSeconds =
    evaluated.length === 0
      ? null
      : Math.round(
          evaluated.reduce(
            (sum, evaluation) => sum + Math.abs(evaluation.error_seconds),
            0,
          ) / evaluated.length,
        );

  return {
    total: relevant.length,
    evaluated: evaluated.length,
    avg_abs_error_seconds: avgAbsErrorSeconds,
  };
}

function buildAccuracySummary(evaluations) {
  const totalAlerts = evaluations.length;
  const evaluatedAlerts = evaluations.filter(
    (evaluation) => typeof evaluation.error_seconds === "number",
  );
  const avgAbsErrorSeconds =
    evaluatedAlerts.length === 0
      ? null
      : Math.round(
          evaluatedAlerts.reduce(
            (sum, evaluation) => sum + Math.abs(evaluation.error_seconds),
            0,
          ) / evaluatedAlerts.length,
        );

  return {
    total_alerts: totalAlerts,
    evaluated_alerts: evaluatedAlerts.length,
    avg_abs_error_seconds: avgAbsErrorSeconds,
    eta_30m: buildAccuracyBucket("alert_eta_30m", evaluations),
    eta_10m: buildAccuracyBucket("alert_eta_10m", evaluations),
    eta_5m: buildAccuracyBucket("alert_eta_5m", evaluations),
  };
}

function clampNumber(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function formatPreciseEtaLabel(seconds) {
  const safeSeconds = Math.max(0, Math.round(seconds));
  const minutes = Math.floor(safeSeconds / 60);
  const remainder = safeSeconds % 60;

  if (minutes <= 0) {
    return `${remainder}s`;
  }

  return `${minutes}m ${`${remainder}`.padStart(2, "0")}s`;
}

function createStopWatchService({
  store,
  runtimeLogger,
  getStopUpcoming,
  getVehicleState,
  getNearbyVehicles,
  historyDir,
  nowFn = Date.now,
}) {
  const watches = new Map();
  let intervalId = null;

  function pushEvent(watch, payload) {
    if (watch.events.some((event) => event.id === payload.id)) {
      return;
    }
    watch.events.unshift(payload);
    trimList(watch.events);
    runtimeLogger?.appendWatchEvent(payload);
  }

  function ensurePolling() {
    if (intervalId || watches.size === 0) {
      return;
    }

    intervalId = setInterval(() => {
      for (const watch of watches.values()) {
        refreshWatch(watch).catch((error) => {
          watch.lastError = error;
        });
      }
    }, WATCH_POLL_MS);
  }

  function maybeStopPolling() {
    if (intervalId && watches.size === 0) {
      clearInterval(intervalId);
      intervalId = null;
    }
  }

  function createWatch(stopId) {
    const stop = store.stopsById.get(Number(stopId));
    if (!stop) {
      return null;
    }

    return {
      stopId: stop.id,
      stop,
      startedAtMs: nowFn(),
      lastRefreshedAtMs: null,
      lastError: null,
      arrivals: [],
      sections: splitArrivalsByConfidence([]),
      refreshHintSeconds: 30,
      entities: new Map(),
      events: [],
      evaluations: [],
      liveVehicles: [],
      historicalLoaded: false,
    };
  }

  function ensureWatch(stopId) {
    const numericStopId = Number(stopId);
    if (!watches.has(numericStopId)) {
      const watch = createWatch(numericStopId);
      if (!watch) {
        return null;
      }
      watches.set(numericStopId, watch);
      ensurePolling();
    }

    return watches.get(numericStopId) || null;
  }

  function maybeTriggerAlert(watch, entity, arrival, nowMs) {
    const effectiveEtaSeconds = arrival.watch_eta_seconds ?? arrival.eta_seconds;
    if (arrival.confidence_state !== "tracking" || effectiveEtaSeconds == null) {
      return;
    }

    const milestone = ALERT_MILESTONES.find(
      (candidate) =>
        effectiveEtaSeconds <= candidate.thresholdSeconds &&
        !entity.alerts.some((alert) => alert.kind === candidate.kind),
    );
    if (!milestone) {
      return;
    }

    const event = {
      id: buildEventId([
        "watch",
        watch.stopId,
        milestone.kind,
        entity.key,
        nowMs,
      ]),
      kind: milestone.kind,
      happened_at: isoStringFromMs(nowMs),
      stop_id: watch.stopId,
      stop_name: watch.stop.name,
      route_id: arrival.route_id,
      route_number: arrival.route_number,
      route_name: arrival.route_name,
      vehicle_uid: arrival.vehicle_uid,
      eta_seconds: effectiveEtaSeconds,
      raw_eta_seconds: arrival.eta_seconds,
      predicted_arrival_at: isoStringFromMs(nowMs + effectiveEtaSeconds * 1000),
      prediction_bias_seconds: arrival.prediction_bias_seconds ?? 0,
      prediction_sample_count: arrival.prediction_sample_count ?? 0,
      ...buildRouteEventFields({
        direction: arrival.direction,
      }),
      message: `${buildTripLabel({
        routeNumber: arrival.route_number,
        routeName: arrival.route_name,
        direction: arrival.direction,
      })} nearing ${watch.stop.name} in about ${milestone.label}${arrival.prediction_bias_seconds != null && arrival.prediction_bias_seconds != 0 ? ` (bias ${arrival.prediction_bias_seconds > 0 ? "+" : ""}${arrival.prediction_bias_seconds}s)` : ""}.`,
    };

    entity.alerts.push(event);
    pushEvent(watch, event);
  }

  function maybeTriggerNearStopAlert(
    watch,
    entity,
    routeLike,
    vehicleState,
    nowMs,
    options = {},
  ) {
    if (entity.lastObservedArrivalAtMs != null) {
      return;
    }

    if (entity.alerts.some((alert) => alert.kind === "alert_near_stop")) {
      return;
    }

    const distanceMeters = haversineDistanceMeters(
      vehicleState.position?.lat ?? null,
      vehicleState.position?.lng ?? null,
      watch.stop.lat,
      watch.stop.lng,
    );
    if (distanceMeters == null || distanceMeters > NEAR_STOP_ALERT_RADIUS_M) {
      return;
    }

    const speedKph = vehicleState.position?.speedKph ?? 0;
    if (
      !vehicleState.moving &&
      speedKph < 5 &&
      (vehicleState.movement_m_90s ?? 0) < 20
    ) {
      return;
    }

    const preciseEtaLabel =
      options.watchEtaLabel ||
      (typeof options.watchEtaSeconds === "number"
        ? formatPreciseEtaLabel(options.watchEtaSeconds)
        : null);

    const event = {
      id: buildEventId([
        "watch",
        watch.stopId,
        "near-stop",
        entity.key,
        nowMs,
      ]),
      kind: "alert_near_stop",
      happened_at: isoStringFromMs(nowMs),
      stop_id: watch.stopId,
      stop_name: watch.stop.name,
      route_id: routeLike.route_id,
      route_number: routeLike.route_number,
      route_name: routeLike.route_name,
      vehicle_uid: routeLike.vehicle_uid ?? vehicleState.uid ?? null,
      eta_seconds: options.watchEtaSeconds ?? null,
      current_stop_distance_m: Math.round(distanceMeters),
      ...buildRouteEventFields({
        direction: routeLike.direction,
        origin_name: routeLike.origin_name,
        destination_name: routeLike.destination_name,
      }),
      message: `${buildTripLabel({
        routeNumber: routeLike.route_number,
        routeName: routeLike.route_name,
        direction: routeLike.direction,
        destinationName: routeLike.destination_name,
      })} now ${Math.round(distanceMeters)}m from ${watch.stop.name}${preciseEtaLabel ? ` with live ETA ${preciseEtaLabel}` : ""}.`,
    };

    entity.alerts.push(event);
    pushEvent(watch, event);
  }

  function maybeTriggerUpstreamPass(
    watch,
    entity,
    arrival,
    vehicleState,
    routeContext,
    nowMs,
  ) {
    const upstreamStop = routeContext?.upstreamStop;
    if (!upstreamStop || entity.lastUpstreamPassAtMs != null) {
      return;
    }

    const distanceMeters = haversineDistanceMeters(
      vehicleState.position?.lat ?? null,
      vehicleState.position?.lng ?? null,
      upstreamStop.lat,
      upstreamStop.lng,
    );
    if (distanceMeters == null || distanceMeters > UPSTREAM_PASS_RADIUS_M) {
      return;
    }

    entity.lastUpstreamPassAtMs = nowMs;
    pushEvent(watch, {
      id: buildEventId(["watch", watch.stopId, "upstream", entity.key, nowMs]),
      kind: "upstream_pass",
      happened_at: isoStringFromMs(nowMs),
      stop_id: watch.stopId,
      stop_name: watch.stop.name,
      route_id: arrival.route_id,
      route_number: arrival.route_number,
      route_name: arrival.route_name,
      vehicle_uid: arrival.vehicle_uid,
      upstream_stop_id: upstreamStop.id,
      upstream_stop_name: upstreamStop.name,
      ...buildRouteEventFields({
        direction: arrival.direction,
      }),
      message: `${buildTripLabel({
        routeNumber: arrival.route_number,
        routeName: arrival.route_name,
        direction: arrival.direction,
      })} just passed ${upstreamStop.name} and is heading for ${watch.stop.name}.`,
    });
  }

  function maybeEvaluateAlerts(watch, entity, arrival, nowMs) {
    for (const alert of entity.alerts) {
      if (alert.evaluated_at) {
        continue;
      }

      const errorSeconds = Math.round(
        (nowMs - new Date(alert.predicted_arrival_at).getTime()) / 1000,
      );
      const evaluation = {
        id: buildEventId([
          "watch",
          watch.stopId,
          "evaluation",
          entity.key,
          alert.kind,
          nowMs,
        ]),
        kind: alert.kind,
        happened_at: isoStringFromMs(nowMs),
        stop_id: watch.stopId,
        stop_name: watch.stop.name,
        route_id: arrival.route_id,
        route_number: arrival.route_number,
        route_name: arrival.route_name,
        vehicle_uid: arrival.vehicle_uid,
        predicted_arrival_at: alert.predicted_arrival_at,
        observed_arrival_at: isoStringFromMs(nowMs),
        error_seconds: errorSeconds,
        ...buildRouteEventFields({
          direction: alert.route_direction || arrival.direction,
          origin_name: alert.origin_name,
          destination_name: alert.destination_name,
        }),
        message: `${buildTripLabel({
          routeNumber: arrival.route_number,
          routeName: arrival.route_name,
          direction: alert.route_direction || arrival.direction,
          destinationName: alert.destination_name,
        })} reached ${watch.stop.name} ${Math.abs(errorSeconds)}s ${errorSeconds >= 0 ? "after" : "before"} predicted time.`,
      };

      alert.evaluated_at = evaluation.happened_at;
      watch.evaluations.unshift(evaluation);
      trimList(watch.evaluations);
      pushEvent(watch, {
        ...evaluation,
        kind: "prediction_evaluated",
      });
    }
  }

  function maybeTriggerObservedArrival(watch, entity, arrival, vehicleState, nowMs) {
    if (entity.lastObservedArrivalAtMs != null) {
      return;
    }

    const distanceMeters = haversineDistanceMeters(
      vehicleState.position?.lat ?? null,
      vehicleState.position?.lng ?? null,
      watch.stop.lat,
      watch.stop.lng,
    );
    if (distanceMeters == null || distanceMeters > OBSERVED_ARRIVAL_RADIUS_M) {
      return;
    }

    entity.lastObservedArrivalAtMs = nowMs;
    pushEvent(watch, {
      id: buildEventId(["watch", watch.stopId, "arrival", entity.key, nowMs]),
      kind: "observed_arrival",
      happened_at: isoStringFromMs(nowMs),
      stop_id: watch.stopId,
      stop_name: watch.stop.name,
      route_id: arrival.route_id,
      route_number: arrival.route_number,
      route_name: arrival.route_name,
      vehicle_uid: arrival.vehicle_uid,
      current_stop_distance_m: Math.round(distanceMeters),
      ...buildRouteEventFields({
        direction: arrival.direction,
      }),
      message: `${buildTripLabel({
        routeNumber: arrival.route_number,
        routeName: arrival.route_name,
        direction: arrival.direction,
      })} reached ${watch.stop.name}.`,
    });
    maybeEvaluateAlerts(watch, entity, arrival, nowMs);
  }

  function maybeTriggerTelemetryObservedPass(
    watch,
    entity,
    routeMeta,
    vehicleState,
    nowMs,
  ) {
    if (entity.lastObservedArrivalAtMs != null) {
      return;
    }

    const distanceMeters = haversineDistanceMeters(
      vehicleState.position?.lat ?? null,
      vehicleState.position?.lng ?? null,
      watch.stop.lat,
      watch.stop.lng,
    );
    if (distanceMeters == null || distanceMeters > TELEMETRY_PASS_RADIUS_M) {
      return;
    }

    const speedKph = vehicleState.position?.speedKph ?? 0;
    if (
      !vehicleState.moving &&
      speedKph < 8 &&
      (vehicleState.movement_m_90s ?? 0) < TELEMETRY_PASS_MIN_MOVEMENT_M
    ) {
      return;
    }

    entity.lastObservedArrivalAtMs = nowMs;
    const routeHeadline = buildRouteHeadline(
      routeMeta.route_number,
      routeMeta.route_name,
      `Bus ${vehicleState.uid}`,
    );
    const syntheticArrival = {
      route_id: routeMeta.route_id,
      route_number: routeMeta.route_number,
      route_name: routeMeta.route_name,
      vehicle_uid: vehicleState.uid,
      direction: routeMeta.direction,
    };

    pushEvent(watch, {
      id: buildEventId([
        "watch",
        watch.stopId,
        "telemetry-pass",
        entity.key,
        nowMs,
      ]),
      kind: "observed_pass",
      happened_at: isoStringFromMs(nowMs),
      stop_id: watch.stopId,
      stop_name: watch.stop.name,
      route_id: routeMeta.route_id,
      route_number: routeMeta.route_number,
      route_name: routeMeta.route_name,
      live_route_id: routeMeta.live_route_id,
      vehicle_uid: vehicleState.uid,
      current_stop_distance_m: Math.round(distanceMeters),
      last_seen_seconds:
        vehicleState.last_seen_seconds ?? vehicleState.ageSeconds ?? null,
      ...buildRouteEventFields(routeMeta),
      message: `${buildTripLabel({
        routeNumber: routeMeta.route_number,
        routeName: routeMeta.route_name,
        direction: routeMeta.direction,
        destinationName: routeMeta.destination_name,
        fallback: routeHeadline,
      })} passed ${watch.stop.name} from live telemetry.`,
    });
    maybeEvaluateAlerts(watch, entity, syntheticArrival, nowMs);
  }

  async function refreshWatch(watch) {
    const nowMs = nowFn();
    await hydrateHistoricalEvaluations(watch, nowMs);
    const stopUpcoming = await getStopUpcoming(watch.stopId);
    const arrivals = normalizeStopUpcoming(store, stopUpcoming, {
      getVehicleState,
      runtimeLogger:
        runtimeLogger?.appendEtaStates && runtimeLogger?.appendWatchEvent
          ? runtimeLogger
          : null,
      stopId: watch.stopId,
      logScope: "watch-stop",
    });
    const decoratedArrivals = arrivals.map((arrival) =>
      decorateWatchArrival(watch, arrival, nowMs),
    );
    const sections = splitArrivalsByConfidence(decoratedArrivals);
    const nearbyVehicles = getNearbyVehicles
      ? getNearbyVehicles(
          watch.stop.lat,
          watch.stop.lng,
          WATCH_LIVE_RADIUS_M,
          8,
        ) || []
      : [];
    const seenKeys = new Set();

    for (const arrival of decoratedArrivals) {
      const key = buildArrivalKey(arrival);
      seenKeys.add(key);

      const entity = watch.entities.get(key) || {
        key,
        alerts: [],
        lastUpstreamPassAtMs: null,
        lastObservedArrivalAtMs: null,
      };
      entity.key = key;
      entity.routeId = arrival.route_id;
      entity.routeNumber = arrival.route_number;
      entity.routeName = arrival.route_name;
      entity.vehicleUid = arrival.vehicle_uid ?? null;
      entity.lastSeenAtMs = nowMs;
      entity.lastEtaSeconds = arrival.watch_eta_seconds ?? arrival.eta_seconds;
      watch.entities.set(key, entity);

      if (arrival.vehicle_uid == null) {
        continue;
      }

      const vehicleState = getVehicleState(arrival.vehicle_uid);
      if (!vehicleState) {
        continue;
      }

      const routeContext = buildRouteContext(store, arrival.route_id, watch.stopId);
      maybeTriggerAlert(watch, entity, arrival, nowMs);
      maybeTriggerUpstreamPass(
        watch,
        entity,
        arrival,
        vehicleState,
        routeContext,
        nowMs,
      );
      maybeTriggerNearStopAlert(watch, entity, arrival, vehicleState, nowMs, {
        watchEtaSeconds: arrival.watch_eta_seconds ?? arrival.eta_seconds,
        watchEtaLabel: arrival.watch_eta_label ?? arrival.eta_label,
      });
      maybeTriggerObservedArrival(watch, entity, arrival, vehicleState, nowMs);
    }

    const liveVehicles = [];

    for (const vehicleState of nearbyVehicles) {
      if (!vehicleState || vehicleState.uid == null) {
        continue;
      }

      const routeMeta = buildVehicleRouteMeta(store, vehicleState);
      const key = buildArrivalKey({ vehicle_uid: vehicleState.uid });
      seenKeys.add(key);

      const entity = watch.entities.get(key) || {
        key,
        alerts: [],
        lastUpstreamPassAtMs: null,
        lastObservedArrivalAtMs: null,
      };
      entity.key = key;
      entity.routeId = routeMeta.route_id;
      entity.routeNumber = routeMeta.route_number;
      entity.routeName = routeMeta.route_name;
      entity.vehicleUid = vehicleState.uid;
      entity.lastSeenAtMs = nowMs;
      watch.entities.set(key, entity);

      maybeTriggerTelemetryObservedPass(
        watch,
        entity,
        routeMeta,
        vehicleState,
        nowMs,
      );
      maybeTriggerNearStopAlert(watch, entity, routeMeta, vehicleState, nowMs);

      const publicVehicle = toWatchLiveVehicle(vehicleState);
      if (publicVehicle) {
        liveVehicles.push(publicVehicle);
      }
    }

    for (const [key, entity] of watch.entities.entries()) {
      if (
        !seenKeys.has(key) &&
        entity.lastSeenAtMs != null &&
        nowMs - entity.lastSeenAtMs > WATCH_ENTITY_TTL_MS
      ) {
        watch.entities.delete(key);
      }
    }

    watch.arrivals = decoratedArrivals;
    watch.sections = sections;
    watch.liveVehicles = liveVehicles;
    watch.lastError = null;
    watch.lastRefreshedAtMs = nowMs;
    watch.refreshHintSeconds = computeRefreshHintSeconds({
      arrivals,
      vehicles: liveVehicles,
    });
    return watch;
  }

  async function hydrateHistoricalEvaluations(watch, nowMs) {
    if (watch.historicalLoaded || !historyDir) {
      return;
    }

    watch.historicalLoaded = true;
    const day = new Date(nowMs).toISOString().slice(0, 10);
    const filePath = path.join(historyDir, day, "watch-events.jsonl");

    try {
      const raw = await fs.readFile(filePath, "utf8");
      const lines = raw
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);

      for (const line of lines) {
        const row = enrichStoredEvent(store, JSON.parse(line));
        if (row.stop_id !== watch.stopId) {
          continue;
        }

        if (
          row.kind === "prediction_evaluated" &&
          typeof row.error_seconds === "number" &&
          !watch.evaluations.some((evaluation) => evaluation.id === row.id)
        ) {
          watch.evaluations.push(row);
        }

        if (
          [
            "upstream_pass",
            "alert_eta_30m",
            "alert_eta_10m",
            "alert_eta_5m",
            "alert_near_stop",
            "observed_arrival",
            "observed_pass",
          ].includes(row.kind) &&
          !watch.events.some((event) => event.id === row.id)
        ) {
          watch.events.push(row);
        }
      }

      watch.evaluations.sort(
        (left, right) =>
          Date.parse(right.happened_at || right.logged_at || 0) -
          Date.parse(left.happened_at || left.logged_at || 0),
      );
      watch.events.sort(
        (left, right) =>
          Date.parse(right.happened_at || right.logged_at || 0) -
          Date.parse(left.happened_at || left.logged_at || 0),
      );
      trimList(watch.evaluations);
      trimList(watch.events);
    } catch (error) {
      if (error.code !== "ENOENT") {
        watch.lastError = error;
      }
    }
  }

  function getHistoricalBiasForRoute(watch, routeId, nowMs) {
    const relevant = watch.evaluations.filter((evaluation) => {
      const happenedAtMs = Date.parse(
        evaluation.happened_at || evaluation.logged_at || 0,
      );
      return (
        evaluation.route_id === routeId &&
        typeof evaluation.error_seconds === "number" &&
        nowMs - happenedAtMs <= HISTORICAL_BIAS_WINDOW_MS
      );
    });

    if (relevant.length === 0) {
      return {
        biasSeconds: 0,
        sampleCount: 0,
      };
    }

    const averageErrorSeconds =
      relevant.reduce((sum, evaluation) => sum + evaluation.error_seconds, 0) /
      relevant.length;
    const weightedBiasSeconds = Math.round(
      averageErrorSeconds * Math.min(1, relevant.length / 3),
    );

    return {
      biasSeconds: clampNumber(
        weightedBiasSeconds,
        -MAX_HISTORICAL_BIAS_SECONDS,
        MAX_HISTORICAL_BIAS_SECONDS,
      ),
      sampleCount: relevant.length,
    };
  }

  function decorateWatchArrival(watch, arrival, nowMs) {
    if (arrival.vehicle_uid == null || arrival.confidence_state !== "tracking") {
      return {
        ...arrival,
        watch_eta_seconds: arrival.eta_seconds,
        watch_eta_label: arrival.eta_label,
        prediction_bias_seconds: 0,
        prediction_sample_count: 0,
      };
    }

    const vehicleState = getVehicleState(arrival.vehicle_uid);
    if (!vehicleState?.position) {
      return {
        ...arrival,
        watch_eta_seconds: arrival.eta_seconds,
        watch_eta_label: arrival.eta_label,
        prediction_bias_seconds: 0,
        prediction_sample_count: 0,
      };
    }

    const directDistanceMeters = haversineDistanceMeters(
      vehicleState.position.lat,
      vehicleState.position.lng,
      watch.stop.lat,
      watch.stop.lng,
    );
    const movementSpeedKph =
      vehicleState.movement_m_90s != null
        ? (vehicleState.movement_m_90s / 90) * 3.6
        : 0;
    const effectiveSpeedKph = Math.max(
      vehicleState.position.speedKph ?? 0,
      movementSpeedKph,
    );
    const directEtaSeconds =
      directDistanceMeters != null && effectiveSpeedKph >= 8
        ? Math.round(directDistanceMeters / (effectiveSpeedKph / 3.6))
        : null;
    const historicalBias = getHistoricalBiasForRoute(
      watch,
      arrival.route_id,
      nowMs,
    );
    const approachAdjustmentSeconds =
      directEtaSeconds == null
        ? 0
        : clampNumber(
            Math.round((directEtaSeconds - arrival.eta_seconds) * 0.5),
            -MAX_APPROACH_ADJUSTMENT_SECONDS,
            MAX_APPROACH_ADJUSTMENT_SECONDS,
          );
    const watchEtaSeconds = Math.max(
      30,
      Math.round(
        arrival.eta_seconds +
          historicalBias.biasSeconds +
          approachAdjustmentSeconds,
      ),
    );

    return {
      ...arrival,
      watch_eta_seconds: watchEtaSeconds,
      watch_eta_label: formatPreciseEtaLabel(watchEtaSeconds),
      raw_eta_label: formatTrackingLabel(arrival.eta_seconds),
      prediction_bias_seconds:
        historicalBias.biasSeconds + approachAdjustmentSeconds,
      prediction_sample_count: historicalBias.sampleCount,
    };
  }

  async function getStopStatus(stopId) {
    const watch = ensureWatch(stopId);
    if (!watch) {
      return null;
    }

    const shouldRefresh =
      watch.lastRefreshedAtMs == null ||
      nowFn() - watch.lastRefreshedAtMs > Math.min(WATCH_POLL_MS, 8_000);
    if (shouldRefresh) {
      await refreshWatch(watch);
    }

    return {
      stop: toStopSummary(watch.stop),
      watch_started_at: isoStringFromMs(watch.startedAtMs),
      refreshed_at: isoStringFromMs(watch.lastRefreshedAtMs),
      refresh_hint_seconds: watch.refreshHintSeconds,
      primary_arrivals: watch.sections.primary_arrivals,
      announced_arrivals: watch.sections.announced_arrivals,
      stale_arrivals: watch.sections.stale_arrivals,
      live_vehicles: watch.liveVehicles.slice(0, 8),
      recent_events: watch.events.slice(0, 20),
      accuracy_summary: buildAccuracySummary(watch.evaluations),
      last_error: watch.lastError?.message || null,
    };
  }

  async function dispose() {
    if (intervalId) {
      clearInterval(intervalId);
      intervalId = null;
    }
    watches.clear();
    maybeStopPolling();
  }

  return {
    ensureWatch,
    getStopStatus,
    refreshWatchByStopId(stopId) {
      const watch = ensureWatch(stopId);
      return watch ? refreshWatch(watch) : null;
    },
    dispose,
  };
}

module.exports = {
  ALERT_MILESTONES,
  NEAR_STOP_ALERT_RADIUS_M,
  OBSERVED_ARRIVAL_RADIUS_M,
  UPSTREAM_PASS_RADIUS_M,
  WATCH_POLL_MS,
  createStopWatchService,
};

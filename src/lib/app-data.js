const {
  buildStaticIndexes,
  decodePolyline,
  getRouteDisplayName,
} = require("./locator");
const { haversineDistanceMeters } = require("./geo");

const BARBADOS_TIME_ZONE = "America/Barbados";
const DEFAULT_NEARBY_RADIUS_METERS = 800;
const DEFAULT_NEARBY_LIMIT = 8;

const ARRIVAL_STATE_ORDER = {
  tracking: 0,
  at_terminal: 1,
  announced: 2,
  stale: 3,
};

function buildBusRouteKey(busId) {
  return `bus-${busId}`;
}

function buildLiveRouteKey(liveRouteId) {
  return `live-${liveRouteId}`;
}

function toRouteSummary(route) {
  return {
    id: route.id,
    route_number: route.routeNumber,
    route_name: route.routeName,
    from: route.from,
    to: route.to,
    source: route.source,
    bus_id: route.busId,
    live_route_id: route.liveRouteId,
    has_live_route: Boolean(route.liveRouteId),
  };
}

function routeSortValue(route) {
  return `${route.routeNumber || ""}|${route.routeName || ""}|${route.id}`;
}

function stopSortValue(stop) {
  return `${stop.name || ""}|${stop.id}`;
}

function coordinatesFromLocatorStop(stop) {
  return {
    lat: stop?.p?.[0]?.y ?? null,
    lng: stop?.p?.[0]?.x ?? null,
  };
}

function formatScheduledTime(secondsSinceEpoch) {
  if (!secondsSinceEpoch) {
    return null;
  }

  return new Date(secondsSinceEpoch * 1000).toISOString();
}

function formatClockLabel(secondsSinceEpoch) {
  if (!secondsSinceEpoch) {
    return "";
  }

  return new Intl.DateTimeFormat("en-BB", {
    timeZone: BARBADOS_TIME_ZONE,
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(secondsSinceEpoch * 1000));
}

function formatTrackingLabel(etaSeconds) {
  if (!etaSeconds || etaSeconds <= 0) {
    return "<1 min";
  }

  return `${Math.max(1, Math.ceil(etaSeconds / 60))} min`;
}

/** Rough bus travel time to a stop from live position (feed ETA sometimes 0 right after departure). */
function estimateBusSecondsToStop(vehicleState, stopLat, stopLng) {
  if (
    vehicleState?.position?.lat == null ||
    vehicleState?.position?.lng == null ||
    stopLat == null ||
    stopLng == null
  ) {
    return null;
  }

  const distanceM = haversineDistanceMeters(
    vehicleState.position.lat,
    vehicleState.position.lng,
    stopLat,
    stopLng,
  );
  if (distanceM == null) {
    return null;
  }

  if (distanceM < 40) {
    return 60;
  }

  const reportedKph = vehicleState.position.speedKph;
  const kph =
    reportedKph != null && reportedKph >= 8
      ? Math.min(50, Math.max(14, reportedKph))
      : 22;
  const seconds = Math.round((distanceM / 1000 / kph) * 3600);
  return Math.min(Math.max(seconds, 45), 7200);
}

function formatWalkLegFromViewer(walkSeconds) {
  if (walkSeconds == null || walkSeconds <= 0) {
    return null;
  }

  const minutes = Math.max(1, Math.ceil(walkSeconds / 60));
  return minutes === 1 ? "~1 min walk from you" : `~${minutes} min walk from you`;
}

function mapConfidenceStatus(confidenceState, lastSeenSeconds) {
  switch (confidenceState) {
    case "tracking":
      return "Tracking";
    case "at_terminal":
      return "At terminal";
    case "stale":
      return `Signal lost${lastSeenSeconds != null ? ` • last seen ${lastSeenSeconds}s ago` : ""}`;
    default:
      return "Announced";
  }
}

function toPublicVehicle(state) {
  if (!state) {
    return null;
  }

  return {
    uid: state.uid,
    route_id: state.routeId,
    route_number: state.routeNumber,
    route_direction: state.routeDirection,
    derived_route_name: state.derivedRouteName,
    trip_schedule_id: state.tripScheduleId,
    delay_seconds: state.delaySeconds,
    age_seconds: state.ageSeconds,
    fresh: state.fresh,
    confidence_state: state.confidence_state,
    confidence_score: state.confidence_score,
    status_text: state.status_text,
    live_tracking: state.live_tracking,
    moving: state.moving,
    movement_m_90s: state.movement_m_90s,
    progress_delta_90s: state.progress_delta_90s,
    origin_distance_m: state.origin_distance_m,
    last_seen_seconds: state.last_seen_seconds,
    lat: state.position?.lat ?? null,
    lng: state.position?.lng ?? null,
    speed_kph: state.position?.speedKph ?? null,
    heading: state.position?.heading ?? null,
    position: {
      lat: state.position?.lat ?? null,
      lng: state.position?.lng ?? null,
      speed_kph: state.position?.speedKph ?? null,
      heading: state.position?.heading ?? null,
    },
    previous_position: state.previous_position || null,
  };
}

function sortArrivals(left, right) {
  return (
    (ARRIVAL_STATE_ORDER[left.confidence_state] ?? 9) -
      (ARRIVAL_STATE_ORDER[right.confidence_state] ?? 9) ||
    left.eta_seconds - right.eta_seconds ||
    `${left.route_number}|${left.route_name}`.localeCompare(
      `${right.route_number}|${right.route_name}`,
    )
  );
}

function normalizeStopRouteArrival(store, liveRouteId, arrival, options = {}) {
  const route = store.routesByLiveRouteId.get(liveRouteId) || null;
  const locatorRoute = store.locatorRoutesById.get(liveRouteId) || null;
  const routeId = route?.id || buildLiveRouteKey(liveRouteId);
  const vehicleState =
    arrival?.uid != null ? options.getVehicleState?.(arrival.uid) || null : null;
  const confidenceState =
    arrival?.uid == null
      ? "announced"
      : vehicleState?.confidence_state || "stale";
  const direction =
    route?.direction ||
    locatorRoute?.d ||
    (locatorRoute
      ? getRouteDisplayName(locatorRoute, store.staticIndexes.stopsById)
      : null);
  const stopRecord =
    options.stopId != null ? store.stopsById.get(options.stopId) : null;

  let etaSeconds = arrival?.eta?.tt ?? 0;
  if (
    confidenceState === "tracking" &&
    vehicleState &&
    stopRecord?.lat != null &&
    stopRecord?.lng != null
  ) {
    const derived = estimateBusSecondsToStop(
      vehicleState,
      stopRecord.lat,
      stopRecord.lng,
    );
    if (derived != null && (!etaSeconds || etaSeconds <= 0)) {
      etaSeconds = derived;
    }
  }

  const etaLabel =
    confidenceState === "tracking"
      ? formatTrackingLabel(etaSeconds)
      : confidenceState === "stale"
      ? `Last seen ${vehicleState?.last_seen_seconds ?? 0}s`
      : formatClockLabel(arrival?.pt);
  const statusText = mapConfidenceStatus(
    confidenceState,
    vehicleState?.last_seen_seconds ?? null,
  );

  let watchEtaSeconds = null;
  let watchEtaLabel = null;
  const viewerLat = options.viewerLat;
  const viewerLng = options.viewerLng;
  if (
    viewerLat != null &&
    viewerLng != null &&
    stopRecord?.lat != null &&
    stopRecord?.lng != null
  ) {
    const walkM = haversineDistanceMeters(
      viewerLat,
      viewerLng,
      stopRecord.lat,
      stopRecord.lng,
    );
    if (walkM != null) {
      const walkSeconds = Math.ceil(walkM / 1.25);
      const walkLeg = formatWalkLegFromViewer(walkSeconds);
      if (confidenceState === "tracking" && walkLeg) {
        watchEtaSeconds = etaSeconds;
        watchEtaLabel = `Bus ${formatTrackingLabel(etaSeconds)} to stop • ${walkLeg}`;
      } else if (confidenceState === "at_terminal" && walkLeg) {
        watchEtaLabel = walkLeg;
      }
    }
  }

  return {
    route_id: routeId,
    route_number: route?.routeNumber || locatorRoute?.n || "",
    route_name:
      route?.routeName ||
      locatorRoute?.d ||
      (locatorRoute ? getRouteDisplayName(locatorRoute, store.staticIndexes.stopsById) : ""),
    direction,
    eta_seconds: etaSeconds,
    eta_label: etaLabel,
    eta_type: arrival?.uid == null ? "schedule" : "live",
    scheduled_time: formatScheduledTime(arrival?.pt),
    scheduled_label: formatClockLabel(arrival?.pt),
    scheduled_timestamp: arrival?.pt ?? null,
    delay_seconds: arrival?.ot ?? 0,
    vehicle_uid: arrival?.uid ?? null,
    freshness:
      confidenceState === "announced"
        ? "schedule"
        : confidenceState === "stale"
        ? "stale"
        : "fresh",
    bus_id: route?.busId ?? null,
    live_route_id: liveRouteId,
    route_source: route?.source || "locator",
    confidence_state: confidenceState,
    confidence_score:
      confidenceState === "announced"
        ? 0.22
        : vehicleState?.confidence_score ?? 0.2,
    status_text: statusText,
    live_tracking:
      confidenceState === "tracking" || confidenceState === "at_terminal",
    last_seen_seconds: vehicleState?.last_seen_seconds ?? null,
    origin_distance_m: vehicleState?.origin_distance_m ?? null,
    movement_m_90s: vehicleState?.movement_m_90s ?? 0,
    progress_delta_90s: vehicleState?.progress_delta_90s ?? 0,
    ...(watchEtaSeconds != null
      ? { watch_eta_seconds: watchEtaSeconds }
      : {}),
    ...(watchEtaLabel != null ? { watch_eta_label: watchEtaLabel } : {}),
  };
}

function buildOfficialRouteRecord(route) {
  return {
    id: buildBusRouteKey(route.busId),
    source: "official",
    busId: route.busId,
    liveRouteId: route.liveRouteId,
    routeNumber: route.routeNumber,
    routeName: route.routeName,
    from: route.from,
    to: route.to,
    direction: route.locatorMatch?.direction || `${route.from} -> ${route.to}`,
    description: route.routeDescription,
    specialNotes: route.specialNotes,
    schedules: route.schedules || {},
    tabId: route.tabId,
    liveRouteUrl: route.liveRouteUrl,
    polyline: route.locatorMatch?.pathPolyline || null,
    stops: route.locatorMatch?.stops || [],
  };
}

function buildLocatorOnlyRouteRecord(route, staticIndexes) {
  const firstStop = staticIndexes.stopsById.get(route.s?.[0]) || null;
  const lastStop = staticIndexes.stopsById.get(route.s?.[route.s.length - 1]) || null;

  return {
    id: buildLiveRouteKey(route.id),
    source: "locator",
    busId: null,
    liveRouteId: route.id,
    routeNumber: route.n,
    routeName: route.d || getRouteDisplayName(route, staticIndexes.stopsById),
    from: firstStop?.n || "Unknown stop",
    to: lastStop?.n || "Unknown stop",
    direction: route.d || getRouteDisplayName(route, staticIndexes.stopsById),
    description: "",
    specialNotes: "",
    schedules: {},
    tabId: null,
    liveRouteUrl: null,
    polyline: route.path || null,
    stops: (route.s || []).map((stopId, index) => {
      const stop = staticIndexes.stopsById.get(stopId) || null;
      const coordinates = stop
        ? coordinatesFromLocatorStop(stop)
        : { lat: null, lng: null };

      return {
        index,
        id: stopId,
        name: stop?.n || null,
        description: stop?.d || null,
        lat: coordinates.lat,
        lng: coordinates.lng,
      };
    }),
  };
}

function buildDataStore({ summary, joinedRoutes, locatorData, transportBoardRoutes }) {
  const staticIndexes = buildStaticIndexes(locatorData);
  const routesByKey = new Map();
  const routesByLiveRouteId = new Map();
  const routesByBusId = new Map();

  for (const joinedRoute of joinedRoutes.routes || []) {
    const routeRecord = buildOfficialRouteRecord(joinedRoute);
    routesByKey.set(routeRecord.id, routeRecord);
    routesByBusId.set(routeRecord.busId, routeRecord);

    if (routeRecord.liveRouteId != null) {
      routesByLiveRouteId.set(routeRecord.liveRouteId, routeRecord);
    }
  }

  for (const locatorRoute of locatorData.routes || []) {
    if (!routesByLiveRouteId.has(locatorRoute.id)) {
      const routeRecord = buildLocatorOnlyRouteRecord(locatorRoute, staticIndexes);
      routesByKey.set(routeRecord.id, routeRecord);
      routesByLiveRouteId.set(routeRecord.liveRouteId, routeRecord);
    }
  }

  const routeIdsByStopId = new Map();

  for (const route of routesByKey.values()) {
    for (const stop of route.stops) {
      if (!routeIdsByStopId.has(stop.id)) {
        routeIdsByStopId.set(stop.id, new Set());
      }
      routeIdsByStopId.get(stop.id).add(route.id);
    }
  }

  const stopsById = new Map();

  for (const stop of locatorData.stops || []) {
    const coordinates = coordinatesFromLocatorStop(stop);
    const routeIds = Array.from(routeIdsByStopId.get(stop.id) || []).sort(
      (left, right) =>
        routeSortValue(routesByKey.get(left)).localeCompare(
          routeSortValue(routesByKey.get(right)),
        ),
    );

    stopsById.set(stop.id, {
      id: stop.id,
      name: stop.n,
      description: stop.d || "",
      lat: coordinates.lat,
      lng: coordinates.lng,
      routes: routeIds
        .map((routeId) => routesByKey.get(routeId))
        .filter(Boolean)
        .map(toRouteSummary),
    });
  }

  const bootstrapRoutes = Array.from(routesByKey.values())
    .sort((left, right) => routeSortValue(left).localeCompare(routeSortValue(right)))
    .map(toRouteSummary);

  const bootstrapStops = Array.from(stopsById.values())
    .sort((left, right) => stopSortValue(left).localeCompare(stopSortValue(right)))
    .map((stop) => ({
      id: stop.id,
      name: stop.name,
      description: stop.description,
      lat: stop.lat,
      lng: stop.lng,
      routes: stop.routes,
    }));

  return {
    summary,
    transportBoardRoutes,
    locatorData,
    staticIndexes,
    routesByKey,
    routesByLiveRouteId,
    routesByBusId,
    locatorRoutesById: staticIndexes.routesById,
    stopsById,
    bootstrapRoutes,
    bootstrapStops,
  };
}

function buildBootstrapPayload(store) {
  return {
    summary: store.summary,
    defaults: {
      nearby_radius_m: DEFAULT_NEARBY_RADIUS_METERS,
      nearby_limit: DEFAULT_NEARBY_LIMIT,
      timezone: BARBADOS_TIME_ZONE,
      refresh_hint_seconds: 5,
    },
    routes: store.bootstrapRoutes,
    stops: store.bootstrapStops,
  };
}

function findNearbyStops(
  store,
  lat,
  lng,
  radiusMeters = DEFAULT_NEARBY_RADIUS_METERS,
  limit = DEFAULT_NEARBY_LIMIT,
) {
  return Array.from(store.stopsById.values())
    .filter((stop) => stop.lat != null && stop.lng != null)
    .map((stop) => ({
      ...stop,
      distance_m: Math.round(
        haversineDistanceMeters(lat, lng, stop.lat, stop.lng),
      ),
    }))
    .filter((stop) => stop.distance_m <= radiusMeters)
    .sort(
      (left, right) =>
        left.distance_m - right.distance_m ||
        stopSortValue(left).localeCompare(stopSortValue(right)),
    )
    .slice(0, limit);
}

function buildConfidenceSummary(arrivals) {
  const summary = {
    tracking: 0,
    at_terminal: 0,
    announced: 0,
    stale: 0,
  };

  for (const arrival of arrivals) {
    if (summary[arrival.confidence_state] != null) {
      summary[arrival.confidence_state] += 1;
    }
  }

  return summary;
}

function splitArrivalsByConfidence(arrivals) {
  const sorted = [...arrivals].sort(sortArrivals);
  return {
    arrivals: sorted,
    primary_arrivals: sorted.filter(
      (arrival) =>
        arrival.confidence_state === "tracking" ||
        arrival.confidence_state === "at_terminal",
    ),
    announced_arrivals: sorted.filter(
      (arrival) => arrival.confidence_state === "announced",
    ),
    stale_arrivals: sorted.filter(
      (arrival) => arrival.confidence_state === "stale",
    ),
  };
}

function computeRefreshHintSeconds({ arrivals = [], vehicles = [] }) {
  const trackingArrival = arrivals.find(
    (arrival) => arrival.confidence_state === "tracking",
  );
  const hasTrackingVehicle = vehicles.some(
    (vehicle) => vehicle.confidence_state === "tracking",
  );
  const hasAtTerminal =
    arrivals.some((arrival) => arrival.confidence_state === "at_terminal") ||
    vehicles.some((vehicle) => vehicle.confidence_state === "at_terminal");

  if (trackingArrival?.eta_seconds != null && trackingArrival.eta_seconds <= 600) {
    return 2;
  }

  if (hasTrackingVehicle || trackingArrival) {
    return 5;
  }

  if (hasAtTerminal) {
    return 10;
  }

  return 20;
}

function logEtaStates(runtimeLogger, scope, arrivals, metadata = {}) {
  if (!runtimeLogger) {
    return;
  }

  for (const arrival of arrivals) {
    runtimeLogger.appendEtaStates({
      scope,
      ...metadata,
      route_id: arrival.route_id,
      route_number: arrival.route_number,
      stop_id: metadata.stop_id ?? null,
      vehicle_uid: arrival.vehicle_uid,
      confidence_state: arrival.confidence_state,
      confidence_score: arrival.confidence_score,
      eta_seconds: arrival.eta_seconds,
      scheduled_timestamp: arrival.scheduled_timestamp,
      live_tracking: arrival.live_tracking,
    });
  }
}

function normalizeStopUpcoming(store, stopUpcoming, options = {}) {
  const routeItems = stopUpcoming?.r || [];
  const arrivals = [];

  for (const routeItem of routeItems) {
    for (const arrival of routeItem.tt || []) {
      arrivals.push(
        normalizeStopRouteArrival(store, routeItem.id, arrival, options),
      );
    }
  }

  const sections = splitArrivalsByConfidence(arrivals);
  logEtaStates(
    options.runtimeLogger,
    options.logScope || "stop-upcoming",
    sections.arrivals,
    {
      stop_id: options.stopId ?? null,
    },
  );
  return sections.arrivals;
}

function buildStopPayload(store, stop, arrivals, vehicles = []) {
  const sections = splitArrivalsByConfidence(arrivals);
  const confidenceSummary = buildConfidenceSummary(sections.arrivals);

  return {
    id: stop.id,
    name: stop.name,
    description: stop.description,
    lat: stop.lat,
    lng: stop.lng,
    routes: stop.routes,
    arrivals: sections.arrivals,
    primary_arrivals: sections.primary_arrivals,
    announced_arrivals: sections.announced_arrivals,
    stale_arrivals: sections.stale_arrivals,
    confidence_summary: confidenceSummary,
    refresh_hint_seconds: computeRefreshHintSeconds({
      arrivals: sections.arrivals,
      vehicles,
    }),
  };
}

function buildNearbyStopResult(store, stop, arrivals, vehicles = []) {
  const payload = buildStopPayload(store, stop, arrivals, vehicles);

  return {
    stop: {
      id: stop.id,
      name: stop.name,
      description: stop.description,
      lat: stop.lat,
      lng: stop.lng,
      routes: stop.routes,
    },
    distance_m: stop.distance_m,
    arrivals: payload.arrivals,
    primary_arrivals: payload.primary_arrivals,
    announced_arrivals: payload.announced_arrivals,
    stale_arrivals: payload.stale_arrivals,
    confidence_summary: payload.confidence_summary,
  };
}

function buildStopDetail(store, stopId, stopUpcoming, options = {}) {
  const stop = store.stopsById.get(stopId);

  if (!stop) {
    return null;
  }

  const arrivals = normalizeStopUpcoming(store, stopUpcoming, {
    ...options,
    stopId,
    logScope: "stop-detail",
  });
  const routeVehicles = stop.routes
    .flatMap((route) =>
      route.live_route_id != null
        ? (options.getVehiclesForRoute?.(route.live_route_id) || []).map(
            toPublicVehicle,
          )
        : [],
    )
    .filter(Boolean);

  return buildStopPayload(store, stop, arrivals, routeVehicles);
}

function buildRouteDetail(store, routeId, activeVehicles = []) {
  const route = store.routesByKey.get(routeId);

  if (!route) {
    return null;
  }

  const publicVehicles = activeVehicles.map(toPublicVehicle).filter(Boolean);

  return {
    id: route.id,
    route_number: route.routeNumber,
    route_name: route.routeName,
    from: route.from,
    to: route.to,
    direction: route.direction,
    source: route.source,
    bus_id: route.busId,
    live_route_id: route.liveRouteId,
    live_route_url: route.liveRouteUrl,
    description: route.description,
    special_notes: route.specialNotes,
    schedules: route.schedules,
    stops: route.stops,
    polyline: route.polyline ? decodePolyline(route.polyline) : [],
    active_vehicles: publicVehicles,
    refresh_hint_seconds: computeRefreshHintSeconds({
      vehicles: publicVehicles,
    }),
  };
}

function buildTrackedRouteSummary(route, activeVehicles = []) {
  const publicVehicles = activeVehicles
    .map(toPublicVehicle)
    .filter(Boolean)
    .sort(
      (left, right) =>
        (ARRIVAL_STATE_ORDER[left.confidence_state] ?? 9) -
          (ARRIVAL_STATE_ORDER[right.confidence_state] ?? 9) ||
        (left.last_seen_seconds ?? 999999) - (right.last_seen_seconds ?? 999999),
    );
  const counts = buildConfidenceSummary(
    publicVehicles.map((vehicle) => ({
      confidence_state: vehicle.confidence_state,
    })),
  );

  return {
    ...toRouteSummary(route),
    direction: route.direction,
    description: route.description || "",
    tracking_count: counts.tracking,
    at_terminal_count: counts.at_terminal,
    stale_count: counts.stale,
    total_vehicles: publicVehicles.length,
    top_state: publicVehicles[0]?.confidence_state || null,
    top_status_text: publicVehicles[0]?.status_text || null,
    active_vehicles: publicVehicles,
    refresh_hint_seconds: computeRefreshHintSeconds({
      vehicles: publicVehicles,
    }),
  };
}

function rankNearbyStop(stopResult) {
  const bestArrival =
    stopResult.primary_arrivals[0] ||
    stopResult.announced_arrivals[0] ||
    stopResult.stale_arrivals[0] ||
    null;

  return {
    stateOrder: bestArrival
      ? ARRIVAL_STATE_ORDER[bestArrival.confidence_state] ?? 9
      : 9,
    etaSeconds: bestArrival?.eta_seconds ?? Number.POSITIVE_INFINITY,
    distanceMeters: stopResult.distance_m,
  };
}

module.exports = {
  BARBADOS_TIME_ZONE,
  DEFAULT_NEARBY_LIMIT,
  DEFAULT_NEARBY_RADIUS_METERS,
  ARRIVAL_STATE_ORDER,
  buildBootstrapPayload,
  buildBusRouteKey,
  buildConfidenceSummary,
  buildDataStore,
  buildLiveRouteKey,
  buildNearbyStopResult,
  buildRouteDetail,
  buildTrackedRouteSummary,
  buildStopDetail,
  buildStopPayload,
  computeRefreshHintSeconds,
  findNearbyStops,
  formatClockLabel,
  formatScheduledTime,
  formatTrackingLabel,
  haversineDistanceMeters,
  logEtaStates,
  normalizeStopUpcoming,
  normalizeStopRouteArrival,
  rankNearbyStop,
  splitArrivalsByConfidence,
  toPublicVehicle,
  toRouteSummary,
};

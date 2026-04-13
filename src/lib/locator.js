const mqtt = require("mqtt");

const DEFAULT_LOCATOR_URL =
  "https://nimbus.wialon.com/locator/7e1577e50406418aa22aaa89cb5ea76a/";

async function fetchText(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status} ${response.statusText} (${url})`);
  }
  return response.text();
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status} ${response.statusText} (${url})`);
  }
  return response.json();
}

function parseAppConfig(locatorHtml, locatorUrl = DEFAULT_LOCATOR_URL) {
  const match = locatorHtml.match(/var APP_CONFIG = '([\s\S]*?)';/);
  if (!match) {
    throw new Error("Could not find APP_CONFIG on locator page");
  }

  const config = JSON.parse(match[1]);
  const url = new URL(locatorUrl);
  const hashMatch = url.pathname.match(/\/locator\/([^/]+)/);

  return {
    locatorUrl,
    origin: url.origin,
    hash: config.hash || hashMatch?.[1] || null,
    name: config.name || null,
    flespiToken: config.flespi_token || null,
    sentryUrl: config.sentry?.url || null,
    sentryServerName: config.sentry?.config?.serverName || null,
  };
}

async function fetchLocatorConfig(locatorUrl = DEFAULT_LOCATOR_URL) {
  const html = await fetchText(locatorUrl);
  return parseAppConfig(html, locatorUrl);
}

function buildApiBase(config) {
  return `${config.origin}/api/locator/${config.hash}`;
}

async function fetchLocatorStaticData(configOrUrl = DEFAULT_LOCATOR_URL) {
  const config =
    typeof configOrUrl === "string"
      ? await fetchLocatorConfig(configOrUrl)
      : configOrUrl;

  const data = await fetchJson(`${buildApiBase(config)}/data`);
  return {
    config,
    data,
  };
}

async function fetchRouteUpcoming(routeId, configOrUrl = DEFAULT_LOCATOR_URL) {
  const config =
    typeof configOrUrl === "string"
      ? await fetchLocatorConfig(configOrUrl)
      : configOrUrl;

  return fetchJson(`${buildApiBase(config)}/online/route/${routeId}`);
}

async function fetchStopUpcoming(stopId, configOrUrl = DEFAULT_LOCATOR_URL) {
  const config =
    typeof configOrUrl === "string"
      ? await fetchLocatorConfig(configOrUrl)
      : configOrUrl;

  return fetchJson(`${buildApiBase(config)}/online/stop/${stopId}`);
}

function buildStaticIndexes(locatorData) {
  const transportTypesByFlag = new Map((locatorData.tp || []).map((item) => [item.f, item]));
  const patternsById = new Map((locatorData.patterns || []).map((item) => [item.id, item]));
  const stopsById = new Map((locatorData.stops || []).map((item) => [item.id, item]));
  const routesById = new Map((locatorData.routes || []).map((item) => [item.id, item]));

  return {
    transportTypesByFlag,
    patternsById,
    stopsById,
    routesById,
  };
}

function getRouteDisplayName(route, stopsById) {
  if (!route || !Array.isArray(route.s) || route.s.length === 0) {
    return "";
  }

  const from = stopsById.get(route.s[0])?.n || "Unknown stop";
  const to = stopsById.get(route.s[route.s.length - 1])?.n || "Unknown stop";
  return `${from} -> ${to}`;
}

function expandRoute(route, indexes) {
  const { stopsById, patternsById, transportTypesByFlag } = indexes;

  return {
    ...route,
    transportType: transportTypesByFlag.get(route.tp) || null,
    derivedName: getRouteDisplayName(route, stopsById),
    stopCount: Array.isArray(route.s) ? route.s.length : 0,
    stops: (route.s || []).map((stopId, index) => {
      const stop = stopsById.get(stopId) || null;
      return stop
        ? {
            index,
            id: stop.id,
            name: stop.n,
            description: stop.d,
            lat: stop.p?.[0]?.y ?? null,
            lng: stop.p?.[0]?.x ?? null,
          }
        : {
            index,
            id: stopId,
            name: null,
            description: null,
            lat: null,
            lng: null,
          };
    }),
    trips: (route.tt || []).map((trip) => ({
      ...trip,
      patternName: patternsById.get(trip.ptrn)?.n || null,
    })),
  };
}

function decodePolyline(encoded, precision = 5) {
  if (!encoded) {
    return [];
  }

  let index = 0;
  let lat = 0;
  let lng = 0;
  const coordinates = [];
  const factor = 10 ** precision;

  while (index < encoded.length) {
    let result = 0;
    let shift = 0;
    let byte;

    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);

    const deltaLat = result & 1 ? ~(result >> 1) : result >> 1;
    lat += deltaLat;

    result = 0;
    shift = 0;

    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);

    const deltaLng = result & 1 ? ~(result >> 1) : result >> 1;
    lng += deltaLng;

    coordinates.push({
      lat: lat / factor,
      lng: lng / factor,
    });
  }

  return coordinates;
}

function isLiveMessageFresh(message, routesById, nowMs = Date.now()) {
  const route = routesById.get(message.msg.r);
  if (!route) {
    return false;
  }

  const ageMs = nowMs - message.msg.t * 1000;
  const isAtLastStop = route.s?.length ? message.msg.i === route.s.length - 1 : false;
  const maxAgeMs = isAtLastStop ? 60_000 : 600_000;

  return ageMs < maxAgeMs;
}

function normalizeLiveMessage(message, indexes, nowMs = Date.now()) {
  const route = indexes.routesById.get(message.msg.r) || null;
  const fresh = isLiveMessageFresh(message, indexes.routesById, nowMs);

  return {
    uid: message.id,
    routeId: message.msg.r,
    routeNumber: route?.n || null,
    routeDirection: route?.d || null,
    derivedRouteName: route ? getRouteDisplayName(route, indexes.stopsById) : null,
    tripScheduleId: message.msg.tt ?? null,
    progressIndex: message.msg.i ?? null,
    delaySeconds: message.msg.o ?? null,
    position: {
      lat: message.msg.pos?.y ?? null,
      lng: message.msg.pos?.x ?? null,
      speedKph: message.msg.pos?.s ?? null,
      heading: message.msg.pos?.c ?? null,
    },
    deviceTimestamp: message.msg.t,
    deviceTimestampIso: new Date(message.msg.t * 1000).toISOString(),
    receivedTimestamp: message.tm,
    receivedTimestampIso: new Date(message.tm * 1000).toISOString(),
    ageSeconds: Math.max(0, Math.round(nowMs / 1000 - message.msg.t)),
    fresh,
  };
}

async function captureLiveSnapshot(configOrUrl = DEFAULT_LOCATOR_URL, options = {}) {
  const config =
    typeof configOrUrl === "string"
      ? await fetchLocatorConfig(configOrUrl)
      : configOrUrl;

  const maxWaitMs = options.maxWaitMs ?? 12_000;
  const idleMs = options.idleMs ?? 1_500;
  const topic = `nimbus/locator/${config.hash}/#`;

  return new Promise((resolve, reject) => {
    const messages = new Map();
    let settled = false;
    let lastMessageAt = Date.now();
    let connectedAt = null;

    const finish = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(killTimer);
      clearInterval(idleTimer);
      client.end(true, () => {
        if (error) {
          reject(error);
          return;
        }

        const snapshot = Array.from(messages.values()).sort((left, right) => left.id - right.id);
        resolve({
          config: {
            hash: config.hash,
            name: config.name,
            locatorUrl: config.locatorUrl,
          },
          topic,
          capturedAt: new Date().toISOString(),
          connectedAt: connectedAt ? new Date(connectedAt).toISOString() : null,
          unitCount: snapshot.length,
          messages: snapshot,
        });
      });
    };

    const client = mqtt.connect("wss://mqtt.flespi.io/", {
      username: config.flespiToken,
      password: "",
      clientId: `nimbus_locator_snapshot_${Date.now()}`,
      clean: true,
      reconnectPeriod: 0,
    });

    const killTimer = setTimeout(() => finish(), maxWaitMs);
    const idleTimer = setInterval(() => {
      if (messages.size > 0 && Date.now() - lastMessageAt >= idleMs) {
        finish();
      }
    }, 250);

    client.on("connect", () => {
      connectedAt = Date.now();
      client.subscribe(topic, (error) => {
        if (error) {
          finish(error);
        }
      });
    });

    client.on("message", (_topic, payload) => {
      lastMessageAt = Date.now();
      const parsed = JSON.parse(payload.toString("utf8"));
      messages.set(parsed.id, parsed);
    });

    client.on("error", (error) => finish(error));
    client.on("close", () => {
      if (!settled && messages.size === 0) {
        finish(new Error("MQTT connection closed before any messages were captured"));
      }
    });
  });
}

module.exports = {
  DEFAULT_LOCATOR_URL,
  buildStaticIndexes,
  captureLiveSnapshot,
  decodePolyline,
  expandRoute,
  fetchLocatorConfig,
  fetchLocatorStaticData,
  fetchRouteUpcoming,
  fetchStopUpcoming,
  getRouteDisplayName,
  isLiveMessageFresh,
  normalizeLiveMessage,
  parseAppConfig,
};

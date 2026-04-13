const cheerio = require("cheerio");

const DEFAULT_ROUTE_FINDER_URL = "https://www.transportboard.com/route-finder/";
const DEFAULT_ROUTE_FINDER_AJAX_URL =
  "https://www.transportboard.com/wp-admin/admin-ajax.php";

async function fetchText(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status} ${response.statusText} (${url})`);
  }
  return response.text();
}

function cleanText(value) {
  return (value || "").replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
}

function htmlSectionToText(html) {
  if (!html) {
    return "";
  }

  const $ = cheerio.load(
    `<div id="content-root">${html
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/(p|div|li|ul|ol|h\d)>/gi, "\n")}</div>`,
  );

  return cleanText($("#content-root").text());
}

async function fetchRouteFinderHtml(routeFinderUrl = DEFAULT_ROUTE_FINDER_URL) {
  return fetchText(routeFinderUrl);
}

function extractRouteIndex(routeFinderHtml) {
  const $ = cheerio.load(routeFinderHtml);
  const routes = [];

  $(".show-single-bus").each((_, element) => {
    const button = $(element);
    const busId = Number(button.attr("data-busid"));
    const tabId = button.closest(".tab-pane").attr("id") || null;

    routes.push({
      busId,
      tabId,
      routeNumber: cleanText(button.find(".route-number").text()),
      routeName: cleanText(button.find(".route-name").text()),
      from: cleanText(button.find(".from").text()).replace(/^From\s+/i, ""),
      to: cleanText(button.find(".to").text()).replace(/^to\s+/i, ""),
    });
  });

  return routes;
}

function parseRouteDetailHtml(detailHtml, busId) {
  const $ = cheerio.load(detailHtml);
  const liveRouteUrl = $("iframe[src*='nimbus.wialon.com/locator/']").attr("src") || null;
  const liveRouteId = liveRouteUrl ? Number(liveRouteUrl.match(/\/route\/(\d+)/)?.[1] || 0) : null;
  const schedules = {};

  $(".schedule").each((_, element) => {
    const schedule = $(element);
    const heading = cleanText(schedule.find("h3").first().text()) || "Unknown";
    const times = schedule
      .html()
      .replace(/<h3[\s\S]*?<\/h3>/i, "")
      .split(/<br\s*\/?>/i)
      .map((item) => cleanText(item))
      .filter(Boolean);

    schedules[heading] = times;
  });

  return {
    busId,
    routeNumber: cleanText($(".bus-header .route-number").first().text()),
    routeName: cleanText($(".bus-header .bus-name").first().text()),
    from: cleanText($(".bus-header .from").first().text()).replace(/towards$/i, "").trim(),
    to: cleanText($(".bus-header .to").first().text()),
    schedules,
    routeDescription: htmlSectionToText($(".bus-route-description .content").html() || ""),
    specialNotes: htmlSectionToText($(".bus-special-notes .content").html() || ""),
    routeDescriptionHtml: $(".bus-route-description .content").html() || "",
    specialNotesHtml: $(".bus-special-notes .content").html() || "",
    liveRouteId: Number.isFinite(liveRouteId) && liveRouteId > 0 ? liveRouteId : null,
    liveRouteUrl,
  };
}

async function fetchRouteDetail(busId, ajaxUrl = DEFAULT_ROUTE_FINDER_AJAX_URL) {
  const body = new URLSearchParams({
    action: "bus_time_table",
    busid: String(busId),
    isAjax: "1",
  });

  const html = await fetchText(ajaxUrl, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
    },
    body,
  });

  return parseRouteDetailHtml(html, busId);
}

async function fetchAllRouteDetails(options = {}) {
  const routeFinderUrl = options.routeFinderUrl || DEFAULT_ROUTE_FINDER_URL;
  const ajaxUrl = options.ajaxUrl || DEFAULT_ROUTE_FINDER_AJAX_URL;
  const concurrency = Number(options.concurrency || 8);
  const html = await fetchRouteFinderHtml(routeFinderUrl);
  const index = extractRouteIndex(html);
  const details = [];

  for (let indexStart = 0; indexStart < index.length; indexStart += concurrency) {
    const batch = index.slice(indexStart, indexStart + concurrency);
    const batchResults = await Promise.all(
      batch.map(async (route) => ({
        ...route,
        ...(await fetchRouteDetail(route.busId, ajaxUrl)),
      })),
    );

    details.push(...batchResults);
  }

  return {
    routeFinderUrl,
    ajaxUrl,
    fetchedAt: new Date().toISOString(),
    totalRoutes: details.length,
    routes: details,
  };
}

module.exports = {
  DEFAULT_ROUTE_FINDER_AJAX_URL,
  DEFAULT_ROUTE_FINDER_URL,
  cleanText,
  extractRouteIndex,
  fetchAllRouteDetails,
  fetchRouteDetail,
  fetchRouteFinderHtml,
  parseRouteDetailHtml,
};

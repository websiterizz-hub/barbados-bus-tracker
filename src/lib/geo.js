function haversineDistanceMeters(startLat, startLng, endLat, endLng) {
  if (
    startLat == null ||
    startLng == null ||
    endLat == null ||
    endLng == null
  ) {
    return null;
  }

  const earthRadiusMeters = 6371000;
  const toRadians = (value) => (value * Math.PI) / 180;
  const dLat = toRadians(endLat - startLat);
  const dLng = toRadians(endLng - startLng);
  const startLatRadians = toRadians(startLat);
  const endLatRadians = toRadians(endLat);

  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(startLatRadians) *
      Math.cos(endLatRadians) *
      Math.sin(dLng / 2) ** 2;

  return (
    2 *
    earthRadiusMeters *
    Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  );
}

module.exports = {
  haversineDistanceMeters,
};

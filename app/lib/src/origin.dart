/// Where distances are measured from.
///
/// Three sources: nothing (no distances shown), the phone's GPS fix, or a
/// point the user picked - either by searching for a place or by tapping on
/// the map. Each origin carries a (lat, lon) and a one-line label for the
/// status row; the picker sources additionally carry the source for the
/// detail sheet.
library;

import 'search.dart';

enum OriginKind { gps, place, map }

class Origin {
  const Origin.gps(this.lat, this.lon)
      : kind = OriginKind.gps,
        place = null,
        label = 'GPS';

  Origin.place(Hit place, {required this.lat, required this.lon})
      : kind = OriginKind.place,
        place = place,
        label = place.name;

  const Origin.map(this.lat, this.lon)
      : kind = OriginKind.map,
        place = null,
        label = 'Map';

  final OriginKind kind;
  final double lat;
  final double lon;
  final Hit? place;
  final String label;

  /// Short description shown in the "Distance from ..." row.
  String describe() {
    return switch (kind) {
      OriginKind.gps => 'GPS',
      OriginKind.place => place!.name,
      OriginKind.map =>
        '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)} (map)',
    };
  }
}
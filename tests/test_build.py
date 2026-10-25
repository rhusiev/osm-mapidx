"""Unit tests for the builder's parts that need no OSM file."""

from __future__ import annotations

import unittest

from shapely.geometry import LineString

from mapidx import build

LAT = 49.84
# Metres per degree of longitude at LAT, for drawing ways a known distance apart
M_PER_DEG = build._m_per_deg_lon(LAT)
# A town's length: two stretches of one name this far apart are two streets
TOWN_M = 5_000


def _way(osm_id: int, start_m: float, end_m: float,
         variants: list[tuple[str, str]] | None = None) -> build._StreetWay:
    """A way along LAT, from start_m to end_m east of longitude 24."""
    line = LineString([(24 + start_m / M_PER_DEG, LAT), (24 + end_m / M_PER_DEG, LAT)])
    return build._StreetWay(osm_id, line, variants or [("name", "Шевченка")],
                            {"name": "Шевченка", "highway": "residential"})


class StreetTests(unittest.TestCase):
    def test_ways_that_meet_or_nearly_meet_are_one_street(self) -> None:
        gap = build.STREET_JOIN_M / 2
        ways = [_way(1, 0, 100), _way(2, 100, 200), _way(3, 200 + gap, 300)]

        streets = build._joined(ways)

        self.assertEqual([[way.osm_id for way in s] for s in streets], [[1, 2, 3]])

    def test_ways_of_one_name_far_apart_are_two_streets(self) -> None:
        ways = [_way(1, 0, 100), _way(2, TOWN_M, TOWN_M + 100)]

        streets = build._joined(ways)

        self.assertEqual(sorted([way.osm_id for way in s] for s in streets), [[1], [2]])

    def test_a_street_is_placed_on_itself_with_every_way_s_names(self) -> None:
        ways = [_way(1, 0, 100, [("name", "Шевченка"), ("name:en", "Shevchenka")]),
                _way(2, 100, 300, [("name", "Шевченка"), ("name:pl", "Szewczenki")])]

        longest, point, variants = build._street_place(ways)

        self.assertEqual(longest.osm_id, 2)
        self.assertAlmostEqual(point.y, LAT)
        self.assertEqual([value for _, value in variants],
                         ["Шевченка", "Shevchenka", "Szewczenki"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
from __future__ import annotations

import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.hr_zone_sync import (
    HrFields,
    compute_hrr_zones,
    diff_hr_fields,
    extract_hr_fields_from_athlete_payload,
    validate_hr_fields,
)


class HrZoneSyncUnitTests(unittest.TestCase):
    def test_compute_hrr_zones_karvonen(self) -> None:
        zones = compute_hrr_zones(hr_max=190, hr_rest=50)
        self.assertEqual(zones["z1"], {"min": 120, "max": 133})
        self.assertEqual(zones["z2"], {"min": 134, "max": 147})
        self.assertEqual(zones["z3"], {"min": 148, "max": 161})
        self.assertEqual(zones["z4"], {"min": 162, "max": 175})
        self.assertEqual(zones["z5"], {"min": 176, "max": 190})

    def test_validate_hr_fields_rejects_rest_gte_max(self) -> None:
        errors = validate_hr_fields(HrFields(hr_max=170, hr_rest=170, lthr=160))
        self.assertIn("hrRest must be lower than hrMax", errors)

    def test_validate_hr_fields_rejects_lthr_above_max(self) -> None:
        errors = validate_hr_fields(HrFields(hr_max=172, hr_rest=52, lthr=175))
        self.assertIn("hrMax must be >= lthr", errors)

    def test_diff_hr_fields_true_when_any_field_changes(self) -> None:
        old = HrFields(hr_max=188, hr_rest=51, lthr=174)
        new = HrFields(hr_max=190, hr_rest=51, lthr=174)
        self.assertTrue(diff_hr_fields(old, new))

    def test_diff_hr_fields_false_when_same(self) -> None:
        old = HrFields(hr_max=188, hr_rest=51, lthr=174)
        new = HrFields(hr_max=188, hr_rest=51, lthr=174)
        self.assertFalse(diff_hr_fields(old, new))

    def test_extract_hr_fields_from_object_payload(self) -> None:
        payload = {
            "id": "i372001",
            "icu_resting_hr": 58,
            "sportSettings": [
                {"types": ["Ride"], "max_hr": 199, "lthr": 175},
                {"types": ["Run", "VirtualRun"], "max_hr": 202, "lthr": 183},
            ],
        }

        fields = extract_hr_fields_from_athlete_payload(payload)
        self.assertEqual(fields, HrFields(hr_max=202, hr_rest=58, lthr=183))

    def test_extract_hr_fields_from_array_payload(self) -> None:
        payload = [
            {
                "id": "i372001",
                "icu_resting_hr": 57,
                "sportSettings": [
                    {"types": ["Run"], "max_hr": 200, "lthr": 181},
                ],
            }
        ]

        fields = extract_hr_fields_from_athlete_payload(payload)
        self.assertEqual(fields, HrFields(hr_max=200, hr_rest=57, lthr=181))

    def test_extract_hr_fields_uses_wellness_resting_fallback(self) -> None:
        payload = {
            "id": "i372001",
            "sportSettings": [
                {"types": ["Run"], "max_hr": 201, "lthr": 182},
            ],
        }

        fields = extract_hr_fields_from_athlete_payload(payload, wellness_resting_hr=55)
        self.assertEqual(fields, HrFields(hr_max=201, hr_rest=55, lthr=182))


if __name__ == "__main__":
    unittest.main()

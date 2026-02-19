from __future__ import annotations

from dataclasses import dataclass
from typing import Dict


ZONE_BANDS = {
    "z1": (0.50, 0.59),
    "z2": (0.60, 0.69),
    "z3": (0.70, 0.79),
    "z4": (0.80, 0.89),
    "z5": (0.90, 1.00),
}


@dataclass(frozen=True)
class HrFields:
    hr_max: int | None
    hr_rest: int | None
    lthr: int | None


def validate_hr_fields(fields: HrFields) -> list[str]:
    errors: list[str] = []
    if fields.hr_max is not None and fields.hr_rest is not None and fields.hr_rest >= fields.hr_max:
        errors.append("hrRest must be lower than hrMax")
    if fields.hr_max is not None and fields.lthr is not None and fields.hr_max < fields.lthr:
        errors.append("hrMax must be >= lthr")
    return errors


def compute_hrr_zones(hr_max: int, hr_rest: int) -> Dict[str, Dict[str, int]]:
    reserve = hr_max - hr_rest
    if reserve <= 0:
        raise ValueError("Invalid HRR inputs: hr_max must be > hr_rest")
    zones: Dict[str, Dict[str, int]] = {}
    for name, (low, high) in ZONE_BANDS.items():
        zones[name] = {
            "min": round(hr_rest + reserve * low),
            "max": round(hr_rest + reserve * high),
        }
    return zones


def diff_hr_fields(old: HrFields, new: HrFields) -> bool:
    return (
        old.hr_max != new.hr_max
        or old.hr_rest != new.hr_rest
        or old.lthr != new.lthr
    )


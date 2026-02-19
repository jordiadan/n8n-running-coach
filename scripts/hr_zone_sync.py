from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict


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


def _to_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        parsed = int(round(float(value)))
    except (TypeError, ValueError):
        return None
    return parsed


def extract_hr_fields_from_athlete_payload(
    payload: Any,
    wellness_resting_hr: int | float | None = None,
) -> HrFields:
    candidates: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        candidates = [payload]
    elif isinstance(payload, list):
        candidates = [item for item in payload if isinstance(item, dict)]

    run_sport: dict[str, Any] | None = None
    athlete_resting_hr: int | None = None

    for candidate in candidates:
        if athlete_resting_hr is None:
            athlete_resting_hr = _to_int(
                candidate.get("icu_resting_hr")
                or candidate.get("restingHR")
                or candidate.get("restingHr")
                or candidate.get("hrRest")
            )

        sport_settings = candidate.get("sportSettings")
        if not isinstance(sport_settings, list):
            continue

        for sport in sport_settings:
            if not isinstance(sport, dict):
                continue
            sport_types = sport.get("types")
            if isinstance(sport_types, list) and any(
                isinstance(value, str) and "run" in value.lower()
                for value in sport_types
            ):
                run_sport = sport
                break
        if run_sport is not None:
            break

    hr_max = _to_int(run_sport.get("max_hr")) if run_sport else None
    lthr = _to_int(run_sport.get("lthr")) if run_sport else None
    hr_rest = athlete_resting_hr if athlete_resting_hr is not None else _to_int(wellness_resting_hr)

    return HrFields(hr_max=hr_max, hr_rest=hr_rest, lthr=lthr)


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

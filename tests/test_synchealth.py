import json
import os
import runpy
import sqlite3
import subprocess
import tempfile
import unittest
from datetime import date
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = ROOT / "bin" / "synchealth-import"
SERVER = ROOT / "bin" / "synchealth-server"
HEALTH = ROOT / "bin" / "health"
TARGETS = ROOT / "health-targets.json"


def health_xml(*elements):
    return "<HealthData>" + "".join(elements) + "</HealthData>"


def quantity(metric, day, value, unit="count", at="12:00:00", source="Test"):
    stamp = f"{day} {at} +0000"
    return (
        f'<Record type="HKQuantityTypeIdentifier{metric}" '
        f'sourceName="{source}" unit="{unit}" startDate="{stamp}" '
        f'endDate="{stamp}" value="{value}"/>'
    )


def category(metric, day, value, start="12:00:00", end="13:00:00"):
    return (
        f'<Record type="HKCategoryTypeIdentifier{metric}" sourceName="Test" '
        f'startDate="{day} {start} +0000" endDate="{day} {end} +0000" '
        f'value="{value}"/>'
    )


class SyncHealthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "home"
        self.db_path = self.home / "health.db"

    def tearDown(self):
        self.temp.cleanup()

    def import_xml(self, xml):
        xml_path = Path(self.temp.name) / "export.xml"
        xml_path.write_text(xml, encoding="utf-8")
        subprocess.run(
            ["/usr/bin/python3", str(IMPORTER), str(xml_path), "--db", str(self.db_path)],
            check=True,
            capture_output=True,
            text=True,
        )

    def connect(self):
        con = sqlite3.connect(self.db_path)
        con.row_factory = sqlite3.Row
        return con

    def test_receiver_initializes_an_empty_database_for_first_full_sync(self):
        server = runpy.run_path(str(SERVER))
        self.home.mkdir()
        with sqlite3.connect(self.db_path) as con:
            server["ensure_database"](con)
            tables = {row[0] for row in con.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )}
        self.assertTrue({"daily", "samples", "private_events", "generic_events"}
                        <= tables)

    def test_dst_interval_uses_timezone_offsets(self):
        module = runpy.run_path(str(IMPORTER))
        minutes = module["minutes_between"](
            "2026-03-08 01:30:00 -0800",
            "2026-03-08 03:30:00 -0700",
        )
        self.assertEqual(minutes, 60.0)

    def test_stand_idle_is_zero_and_reproductive_data_is_private(self):
        day = "2026-03-08"
        xml = health_xml(
            category("AppleStandHour", day, "HKCategoryValueAppleStandHourIdle"),
            category("AppleStandHour", day, "HKCategoryValueAppleStandHourStood",
                     start="14:00:00", end="15:00:00"),
            category("MenstrualFlow", day, "HKCategoryValueMenstrualFlowLight"),
            f'<ActivitySummary dateComponents="{day}" activeEnergyBurned="0" '
            'appleExerciseTime="0" appleStandHours="1" appleMoveTime="0"/>',
        )
        self.import_xml(xml)

        with self.connect() as con:
            stand = con.execute(
                "SELECT value FROM daily WHERE day=? AND metric='AppleStandHour'",
                (day,),
            ).fetchone()[0]
            self.assertEqual(stand, 1.0)
            self.assertIsNone(
                con.execute(
                    "SELECT 1 FROM daily WHERE metric='MenstrualFlow'"
                ).fetchone()
            )
            self.assertEqual(
                con.execute(
                    "SELECT count(*) FROM private_events WHERE type='MenstrualFlow'"
                ).fetchone()[0],
                1,
            )
            self.assertIsNone(
                con.execute(
                    "SELECT 1 FROM sources WHERE metric='MenstrualFlow'"
                ).fetchone()
            )

            # A privacy migration must also remove rows created by an older
            # version, not merely route new imports correctly.
            con.execute(
                "INSERT INTO daily"
                " (day,metric,unit,stat,value,sum,avg,min,max,last,n)"
                " VALUES (?,'MenstrualFlow','count','sum',1,1,1,1,1,1,1)",
                (day,),
            )
            con.execute(
                "INSERT INTO samples(day,metric,at,value,unit)"
                " VALUES (?,'MenstrualFlow',?,1,'count')",
                (day, f"{day} 12:00:00 +0000"),
            )
            con.execute(
                "INSERT INTO sources(metric,source,n)"
                " VALUES ('MenstrualFlow','Legacy',1)"
            )
            con.commit()

        self.import_xml(xml)
        with self.connect() as con:
            for table in ("daily", "samples", "sources"):
                self.assertIsNone(
                    con.execute(
                        f"SELECT 1 FROM {table} WHERE metric='MenstrualFlow'"
                    ).fetchone()
                )

        self.assertEqual(self.home.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.db_path.stat().st_mode & 0o777, 0o600)

    def test_completed_export_day_cannot_be_overwritten_by_partial_push(self):
        self.import_xml(
            health_xml(
                quantity("StepCount", "2026-03-07", 40, at="08:00:00"),
                quantity("StepCount", "2026-03-07", 60, at="18:00:00"),
                quantity("StepCount", "2026-03-08", 10, at="08:00:00"),
                '<ActivitySummary dateComponents="2026-03-07" '
                'activeEnergyBurned="100" appleExerciseTime="20" '
                'appleStandHours="10" appleMoveTime="0"/>',
                '<ActivitySummary dateComponents="2026-03-08" '
                'activeEnergyBurned="10" appleExerciseTime="2" '
                'appleStandHours="1" appleMoveTime="0"/>',
            )
        )
        server = runpy.run_path(str(SERVER))
        payload = {
            "data": {
                "metrics": [{
                    "name": "step_count",
                    "units": "count",
                    "data": [{"date": "2026-03-07 08:00:00 +0000", "qty": 40}],
                }],
                "activity_summaries": [{
                    "date": "2026-03-07",
                    "active_energy": 5,
                    "exercise_time": 1,
                    "stand_hours": 1,
                }],
            }
        }

        with self.connect() as con:
            counts = server["fold"](payload, con)
            value = con.execute(
                "SELECT value FROM daily WHERE day='2026-03-07'"
                " AND metric='StepCount'"
            ).fetchone()[0]
            self.assertEqual(value, 100.0)
            ring_value = con.execute(
                "SELECT active_kcal FROM rings WHERE day='2026-03-07'"
            ).fetchone()[0]
            self.assertEqual(ring_value, 100.0)
            self.assertEqual(counts["export_locked"], 2)

    def test_latest_average_metric_is_not_treated_as_cumulative(self):
        today = date.today().isoformat()
        self.import_xml(
            health_xml(
                quantity("OxygenSaturation", today, 0.98, unit="%"),
            )
        )
        health = runpy.run_path(str(HEALTH))
        targets = json.loads(TARGETS.read_text(encoding="utf-8"))

        with self.connect() as con:
            rows = health["collect"](con, targets)
        oxygen = next(row for row in rows if row["metric"] == "OxygenSaturation")
        self.assertEqual(oxygen["value"], 98.0)
        self.assertEqual(oxygen["day"], today)

    def test_extended_ios_sections_are_queryable_in_private_generic_store(self):
        self.import_xml(
            health_xml(quantity("StepCount", "2026-03-08", 1))
        )
        server = runpy.run_path(str(SERVER))
        payload = {
            "data": {
                "ecg_recordings": [{
                    "id": "ecg-1",
                    "classification": "Sinus Rhythm",
                    "start_date": "2026-03-08 10:00:00 +0000",
                }],
                "medications": [{
                    "id": "med-1",
                    "name": "Example",
                    "start_date": "2026-03-08 11:00:00 +0000",
                }],
                "category_samples": [{
                    "id": "symptom-1",
                    "type": "HKCategoryTypeIdentifierHeadache",
                    "value": 1,
                    "start_date": "2026-03-08 12:00:00 +0000",
                    "end_date": "2026-03-08 12:01:00 +0000",
                }],
            }
        }

        with self.connect() as con:
            counts = server["fold"](payload, con)
            self.assertEqual(counts["generic"], 3)
            self.assertEqual(counts["points"], 3)
            self.assertEqual(
                con.execute("SELECT count(*) FROM generic_events").fetchone()[0],
                3,
            )
            self.assertEqual(
                con.execute(
                    "SELECT day FROM generic_events"
                    " WHERE section='ecg_recordings' AND id='ecg-1'"
                ).fetchone()[0],
                "2026-03-08",
            )


if __name__ == "__main__":
    unittest.main()

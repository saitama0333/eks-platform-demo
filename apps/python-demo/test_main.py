import unittest
import os
import tempfile
from unittest.mock import patch

from main import app


class DemoAppTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.env_patch = patch.dict(
            os.environ,
            {"PERSISTENCE_FILE": os.path.join(self.temp_dir.name, "counter")},
        )
        self.env_patch.start()
        self.client = app.test_client()

    def tearDown(self):
        self.env_patch.stop()
        self.temp_dir.cleanup()

    def test_home_returns_demo_message(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["message"], "Hello from the Python EKS demo")

    def test_health_endpoint(self):
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["status"], "ok")

    def test_readiness_endpoint(self):
        response = self.client.get("/readyz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["status"], "ready")

    def test_persistent_endpoint_increments_its_file_counter(self):
        data_file = os.path.join(self.temp_dir.name, "persistent-counter")
        with patch.dict(os.environ, {"PERSISTENCE_FILE": data_file}):
            first = self.client.get("/persistent").get_json()
            second = self.client.get("/persistent").get_json()

        self.assertEqual(first["persistent_request_count"], 1)
        self.assertEqual(second["persistent_request_count"], 2)


if __name__ == "__main__":
    unittest.main()

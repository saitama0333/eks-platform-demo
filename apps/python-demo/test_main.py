import unittest

from main import app


class DemoAppTests(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

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


if __name__ == "__main__":
    unittest.main()

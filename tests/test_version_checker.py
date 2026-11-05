import importlib.util
import io
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError


CHECKER_PATH = (
    Path(__file__).resolve().parents[1]
    / "deploy"
    / "staging"
    / "check_version.py"
)

spec = importlib.util.spec_from_file_location(
    "staging_version_checker", CHECKER_PATH
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

VERSION_URL = "http://127.0.0.1:8000/version"


class VersionCheckerTests(unittest.TestCase):
    def run_checker(self, payload=b'{"version": "v2"}', error=None):
        response = io.BytesIO(payload)
        response.status = 200

        with (
            patch.object(
                checker.sys,
                "argv",
                ["check_version.py", "v2"],
            ),
            patch.object(
                checker.urllib.request,
                "urlopen",
                return_value=response,
                side_effect=error,
            ) as request,
            redirect_stdout(io.StringIO()),
            redirect_stderr(io.StringIO()),
        ):
            result = checker.main()

        return result, request

    def test_matching_version_passes_and_uses_correct_url(self):
        result, request = self.run_checker()

        self.assertEqual(result, 0)
        request.assert_called_once_with(VERSION_URL, timeout=5)

    def test_wrong_version_fails(self):
        result, _ = self.run_checker(b'{"version": "v3"}')
        self.assertEqual(result, 1)

    def test_missing_version_fails(self):
        result, _ = self.run_checker(b'{"status": "ok"}')
        self.assertEqual(result, 1)

    def test_invalid_json_fails(self):
        result, _ = self.run_checker(b"not-json")
        self.assertEqual(result, 1)

    def test_http_404_fails(self):
        error = HTTPError(
            VERSION_URL, 404, "Not Found", None, None
        )
        result, _ = self.run_checker(error=error)
        self.assertEqual(result, 1)

    def test_connection_error_fails(self):
        result, _ = self.run_checker(
            error=URLError("Connection refused")
        )
        self.assertEqual(result, 1)


if __name__ == "__main__":
    unittest.main()

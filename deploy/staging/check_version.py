import argparse
import json
import sys
import urllib.request


def main():
    parser = argparse.ArgumentParser(
        description="Check the deployed application version."
    )
    parser.add_argument("expected_version")
    args = parser.parse_args()

    url = "http://127.0.0.1:8000/version"

    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            status = response.status
            body = json.load(response)

        if status != 200 or not isinstance(body, dict):
            raise ValueError("Unexpected response from /version")

        actual = body.get("version")

        if actual != args.expected_version:
            raise ValueError(
                f"Version mismatch: expected {args.expected_version!r}, "
                f"got {actual!r}"
            )

    except Exception as error:
        print(f"Version check failed: {error}", file=sys.stderr)
        return 1

    print(f"Version check passed: {actual}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

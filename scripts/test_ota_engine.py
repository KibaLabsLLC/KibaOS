#!/usr/bin/env python3
"""
KibaOS OTA Updater Engine and Verification Test Suite
Verifies payload integrity (SHA-256), HTTPS-only manifest transport,
anti-downgrade policy, and atomic transaction journal rollback recovery.
"""

import json
import hashlib
import os
import sys

class OTAEngine:
    def __init__(self, current_build_number):
        self.current_build_number = current_build_number
        self.accepted_build_number = current_build_number

    def verify_manifest(self, manifest_json, url):
        # Enforce HTTPS-only transport
        if not url.startswith("https://"):
            raise ValueError("Plain HTTP or unencrypted URL rejected")

        try:
            manifest = json.loads(manifest_json)
        except Exception as e:
            raise ValueError(f"Malformed manifest JSON: {e}")

        # Validate required manifest schema fields
        for field in ["manifest_version", "os_version", "build_number", "cabs", "min_update_version"]:
            if field not in manifest:
                raise ValueError(f"Manifest missing required field: {field}")

        build_num = manifest["build_number"]
        if build_num < self.accepted_build_number:
            raise ValueError(f"Downgrade attempt rejected: build {build_num} < current {self.accepted_build_number}")

        if manifest["min_update_version"] > self.current_build_number:
            raise ValueError(f"Incompatible update: minimum build required is {manifest['min_update_version']}")

        return manifest

    def verify_cab(self, cab_data, expected_sha256, expected_size):
        if len(cab_data) != expected_size:
            raise ValueError(f"CAB size mismatch: expected {expected_size}, got {len(cab_data)}")

        computed_hash = hashlib.sha256(cab_data).hexdigest()
        if computed_hash.lower() != expected_sha256.lower():
            raise ValueError(f"CAB SHA-256 mismatch: expected {expected_sha256}, got {computed_hash}")

        return True

    def simulate_journal_apply(self, journal_steps, fail_at_step=-1):
        """
        Simulates atomic staged transaction apply with journal logging and automatic rollback on failure.
        Steps: 1: STAGE_FILES, 2: WRITE_JOURNAL, 3: COMMIT_BOOT_MARKER, 4: SWAP_SYSTEM
        """
        state = "ORIGINAL"
        journal = []

        try:
            for step_idx, step_name in enumerate(journal_steps, 1):
                if step_idx == fail_at_step:
                    raise RuntimeError(f"Interrupted at step {step_name}")
                journal.append(step_name)
                if step_name == "COMMIT_BOOT_MARKER":
                    state = "NEW_STAGED"
                elif step_name == "SWAP_SYSTEM":
                    state = "NEW_ACTIVE"
        except Exception as err:
            # Automatic Rollback Recovery
            state = "ROLLBACK_TO_ORIGINAL"

        return state

def test_engine():
    engine = OTAEngine(current_build_number=100)

    # Test 1: Reject Plain HTTP
    try:
        engine.verify_manifest("{}", "http://example.com/manifest.json")
        assert False, "Should fail on plain HTTP"
    except ValueError:
        pass

    # Test 2: Reject Malformed Manifest
    try:
        engine.verify_manifest("invalid_json", "https://example.com/manifest.json")
        assert False, "Should fail on malformed manifest"
    except ValueError:
        pass

    # Test 3: Reject Downgrade
    downgrade_manifest = json.dumps({
        "manifest_version": 1,
        "os_version": "10.0",
        "build_number": 90,
        "cabs": [],
        "min_update_version": 50
    })
    try:
        engine.verify_manifest(downgrade_manifest, "https://example.com/manifest.json")
        assert False, "Should fail on downgrade"
    except ValueError:
        pass

    # Test 4: Reject Tampered / Truncated CAB
    sample_cab = b"Sample CAB Payload Content"
    valid_hash = hashlib.sha256(sample_cab).hexdigest()

    try:
        engine.verify_cab(b"Truncated", valid_hash, len(sample_cab))
        assert False, "Should fail on size mismatch"
    except ValueError:
        pass

    try:
        engine.verify_cab(b"Tampered Payload Content String!", valid_hash, len(sample_cab))
        assert False, "Should fail on hash mismatch"
    except ValueError:
        pass

    assert engine.verify_cab(sample_cab, valid_hash, len(sample_cab)) == True

    # Test 5: Atomic Staged Journal Step Interrupt & Automatic Rollback
    journal_steps = ["STAGE_FILES", "WRITE_JOURNAL", "COMMIT_BOOT_MARKER", "SWAP_SYSTEM"]
    for fail_step in range(1, 5):
        result_state = engine.simulate_journal_apply(journal_steps, fail_at_step=fail_step)
        assert result_state == "ROLLBACK_TO_ORIGINAL", f"Failed rollback at step {fail_step}"

    # Successful Apply
    assert engine.simulate_journal_apply(journal_steps) == "NEW_ACTIVE"

    print("OTA Engine Verification Tests Passed Successfully!")

if __name__ == '__main__':
    test_engine()

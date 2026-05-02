#!/usr/bin/env python3
"""
approve.py — SMS OTP approval for destructive actions.

Usage:
    python /home/agent/approve.py "delete stack sandbox-longrun-0426"

Flow:
    1. Generates 6-digit OTP
    2. Sends SMS via SNS topic
    3. Waits for user to provide the code (reads from stdin)
    4. Exits 0 on match, exits 1 on failure/timeout
"""

import random
import sys
import time

import boto3

SNS_TOPIC_ARN = "arn:aws:sns:us-east-1:256358067059:sandbox-approval"
REGION = "us-east-1"
TIMEOUT_SECONDS = 300  # 5 minutes


def main():
    if len(sys.argv) < 2:
        print("Usage: python approve.py '<action description>'")
        sys.exit(1)

    action = " ".join(sys.argv[1:])
    otp = f"{random.randint(100000, 999999)}"

    # Send OTP via SNS
    sns = boto3.client("sns", region_name=REGION)
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=f"OpenAB approval code: {otp}\nAction: {action}",
        Subject="OpenAB Approval Required",
    )

    print(f"SMS sent. Waiting for confirmation code (expires in {TIMEOUT_SECONDS // 60} min)...")

    # Wait for code
    start = time.time()
    while time.time() - start < TIMEOUT_SECONDS:
        try:
            code = input("Enter approval code: ").strip()
        except EOFError:
            break
        if code == otp:
            print("APPROVED")
            sys.exit(0)
        print("Wrong code. Try again.")

    print("REJECTED — timeout or invalid code")
    sys.exit(1)


if __name__ == "__main__":
    main()

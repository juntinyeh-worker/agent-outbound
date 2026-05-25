import json
import re
import os
import boto3
from io import BytesIO
from PIL import Image
from urllib.parse import unquote_plus

s3 = boto3.client('s3')
THUMB_MAX = 300
THUMB_QUALITY = 80


def standardize_filename(key: str) -> str:
    """Standardize: lowercase, special chars → hyphens, force .jpg, append _thumb."""
    prefix = '/'.join(key.split('/')[:-1])
    filename = key.split('/')[-1]

    # Split name and extension
    name = '.'.join(filename.split('.')[:-1])

    # Lowercase, replace non-alphanumeric (except hyphens) with hyphens
    name = name.lower()
    name = re.sub(r'[^a-z0-9\-]', '-', name)
    name = re.sub(r'-+', '-', name)  # collapse multiple hyphens
    name = name.strip('-')

    thumb_name = f"{name}_thumb.jpg"
    return f"{prefix}/{thumb_name}" if prefix else thumb_name


def handler(event, context):
    results = []
    invocation_id = event['invocationId']

    for task in event['tasks']:
        task_id = task['taskId']
        s3_key = unquote_plus(task['s3Key'])
        s3_bucket_arn = task['s3BucketArn']
        bucket = s3_bucket_arn.split(':::')[-1]

        try:
            thumb_key = standardize_filename(s3_key)

            # Idempotency: skip if thumbnail exists
            try:
                s3.head_object(Bucket=bucket, Key=thumb_key)
                results.append({
                    'taskId': task_id,
                    'resultCode': 'Succeeded',
                    'resultString': f'Skipped (exists): {thumb_key}'
                })
                continue
            except s3.exceptions.ClientError:
                pass  # Doesn't exist, proceed

            # Download original
            response = s3.get_object(Bucket=bucket, Key=s3_key)
            img = Image.open(BytesIO(response['Body'].read()))
            img = img.convert('RGB')

            # Resize preserving aspect ratio
            img.thumbnail((THUMB_MAX, THUMB_MAX), Image.LANCZOS)

            # Upload thumbnail
            buffer = BytesIO()
            img.save(buffer, format='JPEG', quality=THUMB_QUALITY)
            buffer.seek(0)

            s3.put_object(
                Bucket=bucket,
                Key=thumb_key,
                Body=buffer,
                ContentType='image/jpeg'
            )

            results.append({
                'taskId': task_id,
                'resultCode': 'Succeeded',
                'resultString': f'{s3_key} → {thumb_key}'
            })

        except Exception as e:
            results.append({
                'taskId': task_id,
                'resultCode': 'PermanentFailure',
                'resultString': str(e)[:1024]
            })

    return {
        'invocationSchemaVersion': '1.0',
        'treatMissingKeysAs': 'PermanentFailure',
        'invocationId': invocation_id,
        'results': results
    }

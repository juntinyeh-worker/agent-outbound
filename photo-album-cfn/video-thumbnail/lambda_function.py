import json
import boto3
import os
import subprocess
from urllib.parse import unquote_plus

s3 = boto3.client('s3')

THUMBNAIL_PREFIX = '.thumbnails/'
VIDEO_EXTENSIONS = ('.mov', '.mp4', '.avi', '.mkv', '.webm', '.m4v')
FFMPEG = '/opt/bin/ffmpeg'


def handler(event, context):
    # S3 event trigger
    if 'Records' in event:
        for record in event['Records']:
            bucket = record['s3']['bucket']['name']
            key = unquote_plus(record['s3']['object']['key'])
            if should_process(key):
                generate_video_thumbnail(bucket, key)
        return {'statusCode': 200, 'body': json.dumps({'message': 'Processed S3 event'})}

    # Manual/API trigger (batch)
    body = event if 'bucket' in event else json.loads(event.get('body', '{}'))
    bucket = body['bucket']
    prefix = body.get('prefix', '')
    force = body.get('force', False)

    keys = list_videos(bucket, prefix)
    created = 0
    skipped = 0
    errors = 0

    for key in keys:
        thumb_key = THUMBNAIL_PREFIX + key + '.jpg'
        if not force and object_exists(bucket, thumb_key):
            skipped += 1
            continue
        try:
            generate_video_thumbnail(bucket, key)
            created += 1
        except Exception as e:
            print(f'Error: {key}: {e}')
            errors += 1

    return {
        'statusCode': 200,
        'headers': {'Access-Control-Allow-Origin': '*'},
        'body': json.dumps({
            'message': f'Generated {created} video thumbnails, skipped {skipped}, errors {errors}',
            'created': created,
            'skipped': skipped,
            'errors': errors
        })
    }


def should_process(key):
    lower = key.lower()
    if lower.startswith(THUMBNAIL_PREFIX) or lower.startswith('.meta/'):
        return False
    return any(lower.endswith(ext) for ext in VIDEO_EXTENSIONS)


def list_videos(bucket, prefix):
    keys = []
    paginator = s3.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            if should_process(obj['Key']):
                keys.append(obj['Key'])
    return keys


def object_exists(bucket, key):
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except Exception:
        return False


def generate_video_thumbnail(bucket, key):
    local_video = f'/tmp/{os.path.basename(key)}'
    local_thumb = '/tmp/thumb.jpg'

    # Download video
    s3.download_file(bucket, key, local_video)

    # Extract frame at 1 second (or first frame if video < 1s)
    subprocess.run([
        FFMPEG, '-y', '-i', local_video,
        '-ss', '00:00:01',
        '-frames:v', '1',
        '-vf', 'scale=800:-1',
        '-q:v', '2',
        local_thumb
    ], check=True, capture_output=True, timeout=60)

    # Upload thumbnail
    thumb_key = THUMBNAIL_PREFIX + key + '.jpg'
    s3.upload_file(local_thumb, bucket, thumb_key,
                   ExtraArgs={'ContentType': 'image/jpeg'})

    # Cleanup
    os.remove(local_video)
    if os.path.exists(local_thumb):
        os.remove(local_thumb)

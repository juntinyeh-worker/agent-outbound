import json
import boto3
from io import BytesIO
from PIL import Image
from urllib.parse import unquote_plus

s3 = boto3.client('s3')

THUMBNAIL_PREFIX = '.thumbnails/'
THUMBNAIL_SIZE = (800, 800)
IMAGE_EXTENSIONS = ('.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp')


def handler(event, context):
    # S3 event trigger (single image)
    if 'Records' in event:
        for record in event['Records']:
            bucket = record['s3']['bucket']['name']
            key = unquote_plus(record['s3']['object']['key'])
            if should_process(key):
                generate_thumbnail(bucket, key)
        return {'statusCode': 200, 'body': json.dumps({'message': 'Processed S3 event'})}

    # Manual/API trigger (batch)
    body = event if 'bucket' in event else json.loads(event.get('body', '{}'))
    bucket = body['bucket']
    prefix = body.get('prefix', '')

    keys = list_images(bucket, prefix)
    created = 0
    skipped = 0

    for key in keys:
        thumb_key = THUMBNAIL_PREFIX + key
        if not body.get('force', False) and object_exists(bucket, thumb_key):
            skipped += 1
            continue
        generate_thumbnail(bucket, key)
        created += 1

    return {
        'statusCode': 200,
        'headers': {'Access-Control-Allow-Origin': '*'},
        'body': json.dumps({
            'message': f'Generated {created} thumbnails, skipped {skipped} existing',
            'created': created,
            'skipped': skipped,
            'total': len(keys)
        })
    }


def should_process(key):
    lower = key.lower()
    if lower.startswith(THUMBNAIL_PREFIX) or lower.startswith('.meta/'):
        return False
    return any(lower.endswith(ext) for ext in IMAGE_EXTENSIONS)


def list_images(bucket, prefix):
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


def generate_thumbnail(bucket, key):
    try:
        resp = s3.get_object(Bucket=bucket, Key=key)
        img = Image.open(BytesIO(resp['Body'].read()))

        # Handle EXIF rotation
        try:
            from PIL import ImageOps
            img = ImageOps.exif_transpose(img)
        except Exception:
            pass

        # Convert to RGB if needed (handles RGBA, P mode)
        if img.mode not in ('RGB', 'L'):
            img = img.convert('RGB')

        img.thumbnail(THUMBNAIL_SIZE)

        buf = BytesIO()
        img.save(buf, format='JPEG', quality=80)
        buf.seek(0)

        thumb_key = THUMBNAIL_PREFIX + key
        # Preserve folder structure in thumbnails
        s3.put_object(
            Bucket=bucket,
            Key=thumb_key,
            Body=buf.read(),
            ContentType='image/jpeg'
        )
    except Exception as e:
        print(f'Error processing {key}: {e}')

import json
import boto3
from io import BytesIO
from PIL import Image

s3 = boto3.client('s3')

THUMBNAIL_PREFIX = '.thumbnails/'
THUMBNAIL_SIZE = (800, 800)


def handler(event, context):
    body = json.loads(event.get('body', '{}'))
    bucket = body['bucket']
    key = body['key']
    direction = body.get('direction', 'cw')  # cw or ccw

    angle = -90 if direction == 'cw' else 90

    try:
        # Rotate original
        rotate_image(bucket, key, angle)

        # Rotate thumbnail
        thumb_key = THUMBNAIL_PREFIX + key
        try:
            rotate_image(bucket, thumb_key, angle)
        except Exception:
            # Regenerate thumbnail if it doesn't exist
            generate_thumbnail(bucket, key, thumb_key)

        return {
            'statusCode': 200,
            'headers': {'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'message': 'Rotated', 'key': key})
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': {'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'error': str(e)})
        }


def rotate_image(bucket, key, angle):
    resp = s3.get_object(Bucket=bucket, Key=key)
    img = Image.open(BytesIO(resp['Body'].read()))
    content_type = resp['ContentType']

    rotated = img.rotate(angle, expand=True)

    buf = BytesIO()
    fmt = 'JPEG' if content_type == 'image/jpeg' else img.format or 'JPEG'
    rotated.save(buf, format=fmt, quality=95)
    buf.seek(0)

    s3.put_object(Bucket=bucket, Key=key, Body=buf.read(), ContentType=content_type)


def generate_thumbnail(bucket, original_key, thumb_key):
    resp = s3.get_object(Bucket=bucket, Key=original_key)
    img = Image.open(BytesIO(resp['Body'].read()))

    img.thumbnail(THUMBNAIL_SIZE)

    buf = BytesIO()
    img.save(buf, format='JPEG', quality=80)
    buf.seek(0)

    s3.put_object(Bucket=bucket, Key=thumb_key, Body=buf.read(), ContentType='image/jpeg')

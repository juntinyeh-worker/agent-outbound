import json
import boto3
from io import BytesIO
from datetime import datetime, timedelta
from PIL import Image
import imagehash
import exifread
import numpy as np

s3 = boto3.client('s3')

BURST_TIME_THRESHOLD_SEC = 3
HASH_SIMILARITY_THRESHOLD = 12  # hamming distance
IMAGE_EXTENSIONS = ('.jpg', '.jpeg', '.png', '.heic', '.webp')


def handler(event, context):
    bucket = event.get('bucket')
    prefix = event.get('prefix', '')

    photos = list_photos(bucket, prefix)
    photos_with_meta = []

    for photo in photos:
        meta = extract_metadata(bucket, photo)
        if meta:
            photos_with_meta.append(meta)

    photos_with_meta.sort(key=lambda x: x['timestamp'])
    time_groups = group_by_time(photos_with_meta)
    burst_groups = filter_by_similarity(time_groups)

    removable = sum(len(g['photos']) - 1 for g in burst_groups)

    return {
        'statusCode': 200,
        'body': json.dumps({
            'album': prefix.rstrip('/'),
            'total_photos': len(photos),
            'burst_groups': burst_groups,
            'non_burst_photos': len(photos) - sum(len(g['photos']) for g in burst_groups),
            'potential_savings': f"{removable} photos can be removed if you keep only the best from each group"
        })
    }


def list_photos(bucket, prefix):
    keys = []
    paginator = s3.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            if obj['Key'].lower().endswith(IMAGE_EXTENSIONS):
                keys.append(obj['Key'])
    return keys


def extract_metadata(bucket, key):
    try:
        resp = s3.get_object(Bucket=bucket, Key=key, Range='bytes=0-65535')
        data = resp['Body'].read()
        bio = BytesIO(data)

        tags = exifread.process_file(bio, stop_tag='DateTimeOriginal', details=False)
        dt_tag = tags.get('EXIF DateTimeOriginal') or tags.get('Image DateTime')
        if not dt_tag:
            return None

        timestamp = datetime.strptime(str(dt_tag), '%Y:%m:%d %H:%M:%S')

        bio.seek(0)
        img = Image.open(BytesIO(data))
        img.thumbnail((256, 256))
        phash = imagehash.phash(img)
        sharpness = compute_sharpness(img)

        return {
            'key': key,
            'timestamp': timestamp,
            'phash': phash,
            'sharpness': sharpness
        }
    except Exception:
        return None


def compute_sharpness(img):
    gray = img.convert('L')
    arr = np.array(gray, dtype=np.float64)
    # Laplacian kernel
    laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]], dtype=np.float64)
    from scipy.signal import convolve2d
    filtered = convolve2d(arr, laplacian, mode='valid')
    return float(np.var(filtered))


def group_by_time(photos):
    if not photos:
        return []
    groups = []
    current_group = [photos[0]]

    for i in range(1, len(photos)):
        diff = (photos[i]['timestamp'] - photos[i-1]['timestamp']).total_seconds()
        if diff <= BURST_TIME_THRESHOLD_SEC:
            current_group.append(photos[i])
        else:
            if len(current_group) >= 2:
                groups.append(current_group)
            current_group = [photos[i]]

    if len(current_group) >= 2:
        groups.append(current_group)

    return groups


def filter_by_similarity(time_groups):
    burst_groups = []
    group_id = 0

    for group in time_groups:
        # Check pHash similarity within group
        similar = []
        for i, photo in enumerate(group):
            is_similar_to_any = False
            for other in similar:
                if photo['phash'] - other['phash'] <= HASH_SIMILARITY_THRESHOLD:
                    is_similar_to_any = True
                    break
            if is_similar_to_any or not similar:
                similar.append(photo)

        if len(similar) >= 2:
            group_id += 1
            best = max(similar, key=lambda x: x['sharpness'])
            burst_groups.append({
                'group_id': f'burst-{group_id:03d}',
                'timestamp_range': [
                    similar[0]['timestamp'].isoformat(),
                    similar[-1]['timestamp'].isoformat()
                ],
                'photos': [
                    {'key': p['key'], 'sharpness': round(p['sharpness'], 1)}
                    for p in similar
                ],
                'suggested_keep': best['key']
            })

    return burst_groups

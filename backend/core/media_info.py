"""Базовое определение типа и качества медиа через FFprobe."""
import subprocess
import json
from typing import Dict
from .interfaces import MediaType, QualityTier


def get_media_info(file_path: str) -> Dict:
    """Получить информацию о медиа-файле через ffprobe."""
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries",
        "format=format_name,duration,size,bit_rate"
        ":stream=codec_type,width,height"
        ":stream_disposition=attached_pic",
        "-of", "json",
        file_path
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return json.loads(result.stdout)
    except Exception as e:
        return {"error": str(e)}
    return {}


def _is_image_format(info: Dict) -> bool:
    """Картинку ffprobe отдаёт как видеопоток, поэтому смотрим на формат файла."""
    name = info.get("format", {}).get("format_name", "")
    return name.endswith("_pipe") or name in ("image2", "gif")


def _real_streams(info: Dict) -> list:
    """Потоки без обложек (обложка в mp3 — это не видео)."""
    return [
        s for s in info.get("streams", [])
        if s.get("disposition", {}).get("attached_pic", 0) != 1
    ]


def detect_media_type(file_path: str) -> MediaType:
    """Определить тип медиа: video / audio / image."""
    info = get_media_info(file_path)
    if "error" in info or not info:
        # fallback по расширению
        ext = file_path.lower().rsplit(".", 1)[-1]
        if ext in ("mp4", "mkv", "webm", "avi", "mov"):
            return MediaType.VIDEO
        if ext in ("mp3", "wav", "flac", "aac", "ogg"):
            return MediaType.AUDIO
        if ext in ("jpg", "jpeg", "png", "gif", "webp"):
            return MediaType.IMAGE
        return MediaType.VIDEO  # по умолчанию

    if _is_image_format(info):
        return MediaType.IMAGE

    types = [s.get("codec_type") for s in _real_streams(info)]
    if "video" in types:
        return MediaType.VIDEO
    if "audio" in types:
        return MediaType.AUDIO
    return MediaType.IMAGE


def detect_quality(file_path: str) -> QualityTier:
    """Определить качество видео по высоте кадра."""
    info = get_media_info(file_path)
    for stream in _real_streams(info):
        if stream.get("codec_type") == "video":
            height = stream.get("height", 0)
            if height >= 2160:
                return QualityTier.UHD
            if height > 720:
                return QualityTier.HD
            return QualityTier.SD
    return QualityTier.SD

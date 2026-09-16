"""Базовое определение типа и качества медиа через FFprobe."""
import subprocess
import json
from typing import Dict
from .interfaces import MediaType, QualityTier


def get_media_info(file_path: str) -> Dict:
    """Получить информацию о медиа-файле через ffprobe."""
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration,size,bit_rate:stream=codec_type,width,height",
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


def detect_media_type(file_path: str) -> MediaType:
    """Определить тип медиа: video / audio / image."""
    info = get_media_info(file_path)
    if "error" in info:
        # fallback по расширению
        ext = file_path.lower().rsplit(".", 1)[-1]
        if ext in ("mp4", "mkv", "webm", "avi", "mov"):
            return MediaType.VIDEO
        if ext in ("mp3", "wav", "flac", "aac", "ogg"):
            return MediaType.AUDIO
        if ext in ("jpg", "jpeg", "png", "gif", "webp"):
            return MediaType.IMAGE
        return MediaType.VIDEO  # по умолчанию
    
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "video":
            return MediaType.VIDEO
        if stream.get("codec_type") == "audio":
            return MediaType.AUDIO
    return MediaType.IMAGE


def detect_quality(file_path: str) -> QualityTier:
    """Определить качество видео по высоте кадра."""
    info = get_media_info(file_path)
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "video":
            height = stream.get("height", 0)
            if height >= 2160:
                return QualityTier.UHD
            if height >= 720:
                return QualityTier.HD
            return QualityTier.SD
    return QualityTier.SD

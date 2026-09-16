"""Конфигурация приложения RePlay."""
from dataclasses import dataclass, field
from typing import List


@dataclass
class Settings:
    # === Лимиты Free-плана (на скользящую неделю) ===
    FREE_VIDEO_SECONDS: int = 3 * 3600          # 3 часа видео
    FREE_AUDIO_SECONDS: int = 24 * 3600         # 24 часа аудио
    FREE_IMAGES_COUNT: int = 50                 # 50 изображений

    # === Ограничения по качеству ===
    FREE_MAX_QUALITY: str = "sd"                # до 720p включительно
    PRO_MAX_QUALITY: str = "uhd"                # до 4K

    # === Цены подписок ===
    PRO_PRICE_MONTH: float = 4.99
    PRO_PRICE_YEAR: float = 49.99
    BUSINESS_PRICE_MONTH: float = 14.99
    BUSINESS_PRICE_YEAR: float = 149.99

    # === JWT аутентификация ===
    SECRET_KEY: str = "change-me-in-production"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60

    # === CORS (разрешённые домены) ===
    ALLOWED_ORIGINS: List[str] = field(default_factory=lambda: [
        "http://localhost:3000",
        "http://localhost:5173",
    ])

    # === Загрузка файлов ===
    MAX_UPLOAD_SIZE: int = 5 * 1024 * 1024 * 1024  # 5 GB
    UPLOAD_DIR: str = "/app/uploads"

    # === БД (заполнится позже, когда подключим PostgreSQL) ===
    DATABASE_URL: str = "sqlite:///./replay.db"  # пока SQLite для простоты

    # === Redis (заполнится позже) ===
    REDIS_URL: str = "redis://localhost:6379"


settings = Settings()

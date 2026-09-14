"""
Интерфейсы для всех модулей RePlay.
Новые модули реализуют эти абстракции -> main.py не меняется.
"""
from abc import ABC, abstractmethod
from typing import List, Optional, Dict, Any
from dataclasses import dataclass
from enum import Enum


class MediaType(str, Enum):
    VIDEO = "video"
    AUDIO = "audio"
    IMAGE = "image"


class QualityTier(str, Enum):
    SD = "sd"          # до 720p
    HD = "hd"          # 720p - 1080p
    UHD = "uhd"        # 4K+


@dataclass
class AdSegment:
    """Найденный рекламный сегмент"""
    start_time: float   # секунды
    end_time: float     # секунды
    ad_type: str        # "preroll" | "midroll" | "overlay" | "voiceover" | "hardcoded"
    confidence: float   # 0.0 - 1.0


@dataclass
class ProcessingResult:
    """Результат обработки медиа"""
    success: bool
    output_path: Optional[str] = None
    ad_segments_removed: List[AdSegment] = None
    error: Optional[str] = None
    metadata: Dict[str, Any] = None


# ========== ИНТЕРФЕЙСЫ ==========

class IAdDetector(ABC):
    """Детектор рекламы. Реализации: простой (эвристический), ИИ (OpenAI/Claude/локальная)."""
    
    @abstractmethod
    def detect(self, file_path: str, media_type: MediaType) -> List[AdSegment]:
        """Найти рекламные сегменты в файле"""
        pass


class IAdRemover(ABC):
    """Удаление/замена рекламы. Реализации: cut, blur, inpaint."""
    
    @abstractmethod
    def remove(self, file_path: str, segments: List[AdSegment], method: str) -> ProcessingResult:
        """
        method: "cut" | "blur" | "inpaint"
        """
        pass


class IAIProvider(ABC):
    """
    Провайдер ИИ. Пользователь выбирает какой использовать.
    Реализации: OpenAIProvider, ClaudeProvider, LocalModelProvider, FreeStubProvider.
    """
    
    @abstractmethod
    def analyze(self, file_path: str, task: str) -> Dict[str, Any]:
        """Анализ файла (восстановление, описание, инпейнтинг и т.д.)"""
        pass
    
    @abstractmethod
    def is_available(self) -> bool:
        """Доступен ли провайдер (есть ли ключ, работает ли сервис)"""
        pass
    
    @abstractmethod
    def get_cost(self) -> str:
        """Стоимость использования: "free" | "paid" | описание"""
        pass


class IQuotaManager(ABC):
    """Менеджер лимитов. Считает что израсходовано в Free-плане."""
    
    @abstractmethod
    def check_quota(self, user_id: int, media_type: MediaType, duration_seconds: int, quality: QualityTier) -> Dict:
        """
        Возвращает: {"allowed": bool, "remaining": {...}, "reason": str}
        """
        pass
    
    @abstractmethod
    def consume(self, user_id: int, media_type: MediaType, duration_seconds: int) -> None:
        """Списать использованное"""
        pass


class IFileRecovery(ABC):
    """Восстановление повреждённых файлов"""
    
    @abstractmethod
    def recover(self, file_path: str, depth: str) -> ProcessingResult:
        """
        depth: "simple" (бесплатно) | "deep" (ИИ, платно)
        """
        pass

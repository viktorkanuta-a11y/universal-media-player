"""
Core module for RePlay.
Exports all interfaces and base types.
"""

from .interfaces import (
    MediaType,
    QualityTier,
    AdSegment,
    ProcessingResult,
    IAdDetector,
    IAdRemover,
    IAIProvider,
    IQuotaManager,
    IFileRecovery,
)

__all__ = [
    "MediaType",
    "QualityTier",
    "AdSegment",
    "ProcessingResult",
    "IAdDetector",
    "IAdRemover",
    "IAIProvider",
    "IQuotaManager",
    "IFileRecovery",
]

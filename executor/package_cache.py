"""
Package cache manager for sandbox environments
Phase 2: Package Caching

Provides caching of installed packages to avoid repeated installations
and improve sandbox startup times.
"""

import hashlib
import json
import logging
import os
import time
from typing import Dict, List, Optional, Set, Any
from pathlib import Path

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class PackageCache:
    """
    Manages cache of installed packages for sandboxes.
    
    Caches package installations at the container image level
    to avoid repeated pip/npm installs.
    """
    
    def __init__(self, cache_dir: str = "/tmp/executor-cache"):
        """
        Initialize package cache.
        
        Args:
            cache_dir: Directory for cache storage
        """
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        
        # Cache metadata file
        self.metadata_file = self.cache_dir / "cache-metadata.json"
        self.metadata: Dict[str, dict] = self._load_metadata()
    
    def _load_metadata(self) -> Dict[str, dict]:
        """Load cache metadata from disk."""
        if self.metadata_file.exists():
            try:
                with open(self.metadata_file, 'r') as f:
                    return json.load(f)
            except Exception as e:
                logger.error(f"Failed to load cache metadata: {e}")
        return {}
    
    def _save_metadata(self):
        """Save cache metadata to disk."""
        try:
            with open(self.metadata_file, 'w') as f:
                json.dump(self.metadata, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to save cache metadata: {e}")
    
    def _get_package_hash(self, packages: List[str], language: str = "python") -> str:
        """
        Generate hash for package set.
        
        Args:
            packages: List of packages
            language: Package language
        
        Returns:
            Hash string
        """
        content = json.dumps({
            "language": language,
            "packages": sorted(packages)
        }, sort_keys=True)
        return hashlib.sha256(content.encode()).hexdigest()[:16]
    
    def is_cached(self, packages: List[str], language: str = "python") -> bool:
        """
        Check if package set is cached.
        
        Args:
            packages: List of packages
            language: Package language
        
        Returns:
            True if cached
        """
        if not packages:
            return True
        
        cache_key = self._get_package_hash(packages, language)
        
        if cache_key not in self.metadata:
            return False
        
        # Check if cache directory exists
        cache_path = self.cache_dir / cache_key
        if not cache_path.exists():
            return False
        
        return True
    
    def get_cache_path(self, packages: List[str], language: str = "python") -> Optional[Path]:
        """
        Get cache directory path for package set.
        
        Args:
            packages: List of packages
            language: Package language
        
        Returns:
            Cache path or None if not cached
        """
        if not self.is_cached(packages, language):
            return None
        
        cache_key = self._get_package_hash(packages, language)
        return self.cache_dir / cache_key
    
    def register_cache(
        self,
        packages: List[str],
        language: str = "python",
        container_id: Optional[str] = None,
        size_bytes: int = 0
    ) -> str:
        """
        Register a new cache entry.
        
        Args:
            packages: List of packages
            language: Package language
            container_id: Source container ID
            size_bytes: Cache size in bytes
        
        Returns:
            Cache key
        """
        cache_key = self._get_package_hash(packages, language)
        cache_path = self.cache_dir / cache_key
        cache_path.mkdir(exist_ok=True)
        
        self.metadata[cache_key] = {
            "language": language,
            "packages": sorted(packages),
            "container_id": container_id,
            "size_bytes": size_bytes,
            "created_at": time.time() if 'time' in dir() else 0
        }
        
        self._save_metadata()
        
        logger.info(f"Registered cache: {cache_key} ({len(packages)} packages)")
        return cache_key
    
    def invalidate_cache(self, cache_key: str) -> bool:
        """
        Invalidate a cache entry.
        
        Args:
            cache_key: Cache key to invalidate
        
        Returns:
            True if successful
        """
        try:
            import shutil
            
            # Remove cache directory
            cache_path = self.cache_dir / cache_key
            if cache_path.exists():
                shutil.rmtree(cache_path)
            
            # Remove metadata
            if cache_key in self.metadata:
                del self.metadata[cache_key]
                self._save_metadata()
            
            logger.info(f"Invalidated cache: {cache_key}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to invalidate cache: {e}")
            return False
    
    def get_cache_stats(self) -> Dict[str, Any]:
        """
        Get cache statistics.
        
        Returns:
            Statistics dictionary
        """
        total_size = 0
        entry_count = len(self.metadata)
        
        for cache_key, meta in self.metadata.items():
            cache_path = self.cache_dir / cache_key
            if cache_path.exists():
                try:
                    import subprocess
                    result = subprocess.run(
                        ["du", "-sb", str(cache_path)],
                        capture_output=True,
                        text=True
                    )
                    if result.returncode == 0:
                        size = int(result.stdout.split()[0])
                        total_size += size
                except:
                    pass
        
        return {
            "entry_count": entry_count,
            "total_size_bytes": total_size,
            "total_size_mb": round(total_size / (1024 * 1024), 2),
            "cache_dir": str(self.cache_dir)
        }
    
    def clear_cache(self) -> bool:
        """
        Clear all cached packages.
        
        Returns:
            True if successful
        """
        try:
            import shutil
            
            # Remove all cache directories
            for cache_key in list(self.metadata.keys()):
                cache_path = self.cache_dir / cache_key
                if cache_path.exists():
                    shutil.rmtree(cache_path)
            
            # Clear metadata
            self.metadata = {}
            self._save_metadata()
            
            logger.info("Package cache cleared")
            return True
            
        except Exception as e:
            logger.error(f"Failed to clear cache: {e}")
            return False


# Global cache instance
package_cache = PackageCache()


def get_cached_packages(
    packages: List[str],
    language: str = "python"
) -> Optional[Path]:
    """Get cached packages path (convenience function)."""
    return package_cache.get_cache_path(packages, language)


def is_cached(packages: List[str], language: str = "python") -> bool:
    """Check if packages are cached (convenience function)."""
    return package_cache.is_cached(packages, language)

"""
Filesystem utilities for sandbox operations
Phase 2: Enhanced File Operations

Provides secure file operations with validation, directory support,
and size limits.
"""

import os
import tarfile
import logging
from io import BytesIO
from typing import List, Dict, Optional, Tuple, Union, Any
from pathlib import Path
import re

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class FileSystemError(Exception):
    """Base exception for filesystem operations."""
    pass


class PathSecurityError(FileSystemError):
    """Raised when a path violates security constraints."""
    pass


class FileSizeError(FileSystemError):
    """Raised when file size exceeds limits."""
    pass


class SecurePathValidator:
    """
    Validates paths for security constraints.
    
    Prevents:
    - Path traversal attacks (../)
    - Absolute paths outside workspace
    - Symlink attacks
    - Dangerous file extensions
    """
    
    # Dangerous extensions that should be blocked
    DANGEROUS_EXTENSIONS = {
        '.exe', '.dll', '.so', '.dylib',  # Executables
        '.sh', '.bash', '.zsh',  # Shell scripts (in certain contexts)
        '.pyo', '.pyc',  # Python bytecode
    }
    
    # Allowed characters in filenames
    SAFE_FILENAME_PATTERN = re.compile(r'^[\w\-\.]+$')
    
    def __init__(self, base_path: str = "/workspace"):
        """
        Initialize validator.
        
        Args:
            base_path: Base directory for all operations
        """
        self.base_path = Path(base_path).resolve()
    
    def validate(self, path: str, allow_dirs: bool = True) -> str:
        """
        Validate and sanitize a path.
        
        Args:
            path: Input path
            allow_dirs: Whether to allow directory paths
        
        Returns:
            Sanitized relative path
        
        Raises:
            PathSecurityError: If path violates security constraints
        """
        if not path:
            raise PathSecurityError("Empty path")
        
        # Normalize path
        path = path.strip()
        
        # Check for null bytes
        if '\x00' in path:
            raise PathSecurityError("Path contains null bytes")
        
        # Convert to Path object and normalize
        try:
            target = Path(path)
        except Exception as e:
            raise PathSecurityError(f"Invalid path: {e}")
        
        # Check for path traversal attempts
        if '..' in target.parts:
            raise PathSecurityError(f"Path traversal detected: {path}")
        
        # Ensure path is relative
        if target.is_absolute():
            raise PathSecurityError(f"Absolute paths not allowed: {path}")
        
        # Resolve against base path
        full_path = (self.base_path / target).resolve()
        
        # Ensure resolved path is within base directory
        try:
            full_path.relative_to(self.base_path)
        except ValueError:
            raise PathSecurityError(
                f"Path escapes base directory: {path}"
            )
        
        # Validate individual path components
        for part in target.parts:
            if part in ('.', '..'):
                continue
            
            if not self.SAFE_FILENAME_PATTERN.match(part):
                raise PathSecurityError(
                    f"Invalid characters in path component: {part}"
                )
            
            # Check for dangerous extensions
            lower_part = part.lower()
            for ext in self.DANGEROUS_EXTENSIONS:
                if lower_part.endswith(ext):
                    raise PathSecurityError(
                        f"Dangerous file extension not allowed: {ext}"
                    )
        
        # Return sanitized relative path
        return str(target).lstrip('/')


class FileSystemManager:
    """
    Manages filesystem operations within sandbox containers.
    
    Features:
    - Directory operations (create, list, delete)
    - File size limits
    - Batch operations
    - Security validation
    - Archive support (tar)
    """
    
    def __init__(
        self,
        container,
        max_file_size: int = 10 * 1024 * 1024,  # 10MB
        max_total_size: int = 100 * 1024 * 1024,  # 100MB
        base_path: str = "/workspace"
    ):
        """
        Initialize filesystem manager.
        
        Args:
            container: Docker container instance
            max_file_size: Maximum size for single file
            max_total_size: Maximum total storage per sandbox
            base_path: Base directory in container
        """
        self.container = container
        self.max_file_size = max_file_size
        self.max_total_size = max_total_size
        self.base_path = base_path
        self.validator = SecurePathValidator(base_path)
    
    def write_file(
        self,
        path: str,
        content: Union[str, bytes],
        encoding: str = 'utf-8'
    ) -> Dict[str, Any]:
        """
        Write file to sandbox with validation.
        
        Args:
            path: File path
            content: File content (str or bytes)
            encoding: Encoding for string content
        
        Returns:
            Operation result with metadata
        """
        try:
            # Validate path
            safe_path = self.validator.validate(path)
            
            # Convert content to bytes
            if isinstance(content, str):
                content_bytes = content.encode(encoding)
            else:
                content_bytes = content
            
            # Check file size
            if len(content_bytes) > self.max_file_size:
                raise FileSizeError(
                    f"File size {len(content_bytes)} exceeds limit "
                    f"{self.max_file_size}"
                )
            
            # Check total storage
            current_usage = self.get_storage_usage()
            if current_usage + len(content_bytes) > self.max_total_size:
                raise FileSizeError(
                    f"Total storage would exceed limit {self.max_total_size}"
                )
            
            # Create tar archive
            tar_stream = BytesIO()
            with tarfile.open(fileobj=tar_stream, mode='w') as tar:
                info = tarfile.TarInfo(name=safe_path)
                info.size = len(content_bytes)
                info.uid = 1000
                info.gid = 1000
                tar.addfile(info, BytesIO(content_bytes))
            
            tar_stream.seek(0)
            
            # Upload to container
            success = self.container.put_archive(self.base_path, tar_stream)
            
            if success:
                logger.debug(f"File written: {safe_path}")
                return {
                    "success": True,
                    "path": safe_path,
                    "size": len(content_bytes)
                }
            else:
                return {
                    "success": False,
                    "error": "Failed to upload file to container"
                }
                
        except (PathSecurityError, FileSizeError) as e:
            logger.warning(f"File write rejected: {e}")
            return {"success": False, "error": str(e)}
        except Exception as e:
            logger.error(f"File write failed: {e}")
            return {"success": False, "error": f"Internal error: {e}"}
    
    def read_file(
        self,
        path: str,
        encoding: str = 'utf-8',
        max_size: Optional[int] = None
    ) -> Dict[str, Any]:
        """
        Read file from sandbox with validation.
        
        Args:
            path: File path
            encoding: Encoding for string content
            max_size: Override max file size limit
        
        Returns:
            Operation result with content or error
        """
        max_size = max_size or self.max_file_size
        
        try:
            # Validate path
            safe_path = self.validator.validate(path)
            full_path = f"{self.base_path}/{safe_path}"
            
            # Get file from container
            bits, stat = self.container.get_archive(full_path)
            
            if not bits:
                return {"success": False, "error": "File not found"}
            
            # Read archive
            file_buffer = BytesIO()
            for chunk in bits:
                file_buffer.write(chunk)
            file_buffer.seek(0)
            
            # Extract content
            with tarfile.open(fileobj=file_buffer, mode='r') as tar:
                member = tar.getmembers()[0]
                
                # Check size before extraction
                if member.size > max_size:
                    raise FileSizeError(
                        f"File size {member.size} exceeds limit {max_size}"
                    )
                
                extracted = tar.extractfile(member)
                if extracted is None:
                    return {"success": False, "error": "Failed to extract file"}
                
                content_bytes = extracted.read()
                
                # Try to decode as text
                try:
                    content = content_bytes.decode(encoding)
                    is_binary = False
                except UnicodeDecodeError:
                    content = content_bytes
                    is_binary = True
                
                return {
                    "success": True,
                    "path": safe_path,
                    "content": content,
                    "size": len(content_bytes),
                    "is_binary": is_binary
                }
                
        except FileSizeError as e:
            return {"success": False, "error": str(e)}
        except Exception as e:
            logger.error(f"File read failed: {e}")
            return {"success": False, "error": f"Internal error: {e}"}
    
    def create_directory(self, path: str) -> Dict[str, Any]:
        """
        Create directory in sandbox.
        
        Args:
            path: Directory path
        
        Returns:
            Operation result
        """
        try:
            safe_path = self.validator.validate(path)
            full_path = f"{self.base_path}/{safe_path}"
            
            # Create directory using mkdir command
            result = self.container.exec_run(
                ["mkdir", "-p", full_path],
                user="sandbox"
            )
            
            if result.exit_code == 0:
                return {"success": True, "path": safe_path}
            else:
                return {
                    "success": False,
                    "error": f"mkdir failed: {result.output}"
                }
                
        except PathSecurityError as e:
            return {"success": False, "error": str(e)}
        except Exception as e:
            logger.error(f"Directory creation failed: {e}")
            return {"success": False, "error": str(e)}
    
    def list_directory(
        self,
        path: str = ".",
        include_hidden: bool = False
    ) -> Dict[str, Any]:
        """
        List directory contents.
        
        Args:
            path: Directory path
            include_hidden: Whether to include hidden files
        
        Returns:
            Operation result with file list
        """
        try:
            safe_path = self.validator.validate(path)
            full_path = f"{self.base_path}/{safe_path}"
            
            # List directory using ls command
            cmd = ["ls", "-la", full_path]
            result = self.container.exec_run(cmd, user="sandbox")
            
            if result.exit_code != 0:
                return {
                    "success": False,
                    "error": f"ls failed: {result.output}"
                }
            
            # Parse ls output
            entries = []
            stdout = result.output[0].decode('utf-8') if result.output[0] else ""
            
            for line in stdout.split('\n')[1:]:  # Skip total line
                if not line.strip():
                    continue
                
                parts = line.split()
                if len(parts) < 9:
                    continue
                
                name = parts[8]
                if name in ('.', '..'):
                    continue
                
                if not include_hidden and name.startswith('.'):
                    continue
                
                entry = {
                    "name": name,
                    "type": "directory" if parts[0].startswith('d') else "file",
                    "size": int(parts[4]) if parts[4].isdigit() else 0,
                    "permissions": parts[0],
                    "owner": parts[2],
                    "group": parts[3]
                }
                entries.append(entry)
            
            return {
                "success": True,
                "path": safe_path,
                "entries": entries
            }
            
        except Exception as e:
            logger.error(f"Directory listing failed: {e}")
            return {"success": False, "error": str(e)}
    
    def delete(self, path: str, recursive: bool = False) -> Dict[str, Any]:
        """
        Delete file or directory.
        
        Args:
            path: Path to delete
            recursive: Whether to delete directories recursively
        
        Returns:
            Operation result
        """
        try:
            safe_path = self.validator.validate(path)
            full_path = f"{self.base_path}/{safe_path}"
            
            # Build rm command
            cmd = ["rm"]
            if recursive:
                cmd.append("-r")
            cmd.append(full_path)
            
            result = self.container.exec_run(cmd, user="sandbox")
            
            if result.exit_code == 0:
                return {"success": True, "path": safe_path}
            else:
                error_msg = result.output[1].decode('utf-8') if result.output[1] else "Unknown error"
                return {"success": False, "error": error_msg}
                
        except PathSecurityError as e:
            return {"success": False, "error": str(e)}
        except Exception as e:
            logger.error(f"Delete failed: {e}")
            return {"success": False, "error": str(e)}
    
    def get_storage_usage(self) -> int:
        """
        Get total storage usage in bytes.
        
        Returns:
            Total bytes used
        """
        try:
            result = self.container.exec_run(
                ["du", "-sb", self.base_path],
                user="sandbox"
            )
            
            if result.exit_code == 0:
                stdout = result.output[0].decode('utf-8').strip()
                size = int(stdout.split()[0])
                return size
            else:
                return 0
                
        except Exception as e:
            logger.error(f"Failed to get storage usage: {e}")
            return 0
    
    def batch_write(
        self,
        files: Dict[str, Union[str, bytes]]
    ) -> Dict[str, Any]:
        """
        Write multiple files in batch.
        
        Args:
            files: Dict of path -> content
        
        Returns:
            Batch operation results
        """
        results = {}
        total_size = sum(
            len(content) if isinstance(content, bytes) else len(content.encode())
            for content in files.values()
        )
        
        # Check total size
        if total_size > self.max_total_size:
            return {
                "success": False,
                "error": f"Batch size {total_size} exceeds limit {self.max_total_size}"
            }
        
        # Create combined tar archive
        try:
            tar_stream = BytesIO()
            with tarfile.open(fileobj=tar_stream, mode='w') as tar:
                for path, content in files.items():
                    try:
                        safe_path = self.validator.validate(path)
                        
                        if isinstance(content, str):
                            content_bytes = content.encode('utf-8')
                        else:
                            content_bytes = content
                        
                        info = tarfile.TarInfo(name=safe_path)
                        info.size = len(content_bytes)
                        info.uid = 1000
                        info.gid = 1000
                        tar.addfile(info, BytesIO(content_bytes))
                        results[safe_path] = {"success": True}
                        
                    except PathSecurityError as e:
                        results[path] = {"success": False, "error": str(e)}
            
            tar_stream.seek(0)
            success = self.container.put_archive(self.base_path, tar_stream)
            
            if not success:
                return {
                    "success": False,
                    "error": "Failed to upload batch to container",
                    "results": results
                }
            
            return {
                "success": True,
                "results": results,
                "total_files": len(files),
                "successful": sum(1 for r in results.values() if r.get("success"))
            }
            
        except Exception as e:
            logger.error(f"Batch write failed: {e}")
            return {"success": False, "error": str(e)}


def format_size(size_bytes: float) -> str:
    """Format byte size to human readable string."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.2f} TB"

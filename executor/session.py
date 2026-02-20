"""
Session Manager for CodeSandbox
Phase 2: Enhanced Execution Management

Provides session lifecycle management with TTL, concurrent execution,
and resource pooling for sandbox containers.
"""

import logging
import threading
import time
import uuid
from typing import Dict, List, Optional, Any, Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
import json

from executor.sandbox import CodeSandbox

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@dataclass
class Session:
    """Represents a sandbox session."""
    id: str
    sandbox: CodeSandbox
    template: str
    created_at: float
    last_used: float
    ttl: int  # Time to live in seconds
    metadata: Dict[str, Any] = field(default_factory=dict)
    is_active: bool = True
    use_count: int = 0
    
    @property
    def age(self) -> float:
        """Get session age in seconds."""
        return time.time() - self.created_at
    
    @property
    def idle_time(self) -> float:
        """Get idle time in seconds."""
        return time.time() - self.last_used
    
    @property
    def is_expired(self) -> bool:
        """Check if session has exceeded TTL."""
        return self.idle_time > self.ttl
    
    def touch(self):
        """Update last used timestamp."""
        self.last_used = time.time()
        self.use_count += 1


class SessionManager:
    """
    Manages sandbox sessions with TTL and concurrent execution support.
    
    Features:
    - Session pooling and reuse
    - Automatic cleanup of expired sessions
    - Concurrent session limit
    - Session metadata and tracking
    - Background cleanup thread
    """
    
    def __init__(
        self,
        default_ttl: int = 300,  # 5 minutes
        max_sessions: int = 10,
        cleanup_interval: int = 60,  # 1 minute
        enable_cleanup_thread: bool = True
    ):
        """
        Initialize session manager.
        
        Args:
            default_ttl: Default session TTL in seconds
            max_sessions: Maximum concurrent sessions
            cleanup_interval: Cleanup thread interval in seconds
            enable_cleanup_thread: Whether to enable background cleanup
        """
        self.default_ttl = default_ttl
        self.max_sessions = max_sessions
        self.cleanup_interval = cleanup_interval
        
        self.sessions: Dict[str, Session] = {}
        self._lock = threading.RLock()
        self._cleanup_thread: Optional[threading.Thread] = None
        self._stop_cleanup = threading.Event()
        
        # Metrics
        self.metrics = {
            "sessions_created": 0,
            "sessions_reused": 0,
            "sessions_destroyed": 0,
            "sessions_expired": 0,
            "errors": 0
        }
        
        if enable_cleanup_thread:
            self._start_cleanup_thread()
    
    def create_session(
        self,
        template: str = "default",
        ttl: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **sandbox_kwargs
    ) -> str:
        """
        Create a new sandbox session.
        
        Args:
            template: Environment template name
            ttl: Session TTL (uses default if not specified)
            metadata: Additional session metadata
            **sandbox_kwargs: Additional arguments for CodeSandbox
        
        Returns:
            Session ID
        """
        ttl = ttl or self.default_ttl
        
        with self._lock:
            # Check session limit
            if len(self.sessions) >= self.max_sessions:
                # Try to cleanup expired sessions first
                self._cleanup_expired()
                
                if len(self.sessions) >= self.max_sessions:
                    raise RuntimeError(
                        f"Maximum session limit reached ({self.max_sessions}). "
                        "Destroy existing sessions or increase limit."
                    )
            
            # Create sandbox
            try:
                sandbox = CodeSandbox(**sandbox_kwargs)
                sandbox.create()
                
                session_id = str(uuid.uuid4())[:12]
                session = Session(
                    id=session_id,
                    sandbox=sandbox,
                    template=template,
                    created_at=time.time(),
                    last_used=time.time(),
                    ttl=ttl,
                    metadata=metadata or {}
                )
                
                self.sessions[session_id] = session
                self.metrics["sessions_created"] += 1
                
                logger.info(f"Session created: {session_id} (template: {template})")
                return session_id
                
            except Exception as e:
                self.metrics["errors"] += 1
                logger.error(f"Failed to create session: {e}")
                raise
    
    def get_session(self, session_id: str) -> Optional[Session]:
        """
        Get existing session by ID.
        
        Args:
            session_id: Session identifier
        
        Returns:
            Session object or None if not found/expired
        """
        with self._lock:
            session = self.sessions.get(session_id)
            
            if not session:
                return None
            
            if not session.is_active:
                logger.warning(f"Session {session_id} is inactive")
                return None
            
            if session.is_expired:
                logger.info(f"Session {session_id} expired, destroying")
                self._destroy_session_unlocked(session_id)
                return None
            
            session.touch()
            self.metrics["sessions_reused"] += 1
            
            return session
    
    def execute_in_session(
        self,
        session_id: str,
        code: str,
        language: str = "python",
        files: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """
        Execute code in an existing session.
        
        Args:
            session_id: Session identifier
            code: Code to execute
            language: Programming language
            files: Files to upload
        
        Returns:
            Execution result
        """
        session = self.get_session(session_id)
        
        if not session:
            return {
                "status": "error",
                "error": f"Session {session_id} not found or expired",
                "exit_code": -1
            }
        
        try:
            result = session.sandbox.run_code(code, language, files)
            return result
        except Exception as e:
            logger.error(f"Execution error in session {session_id}: {e}")
            return {
                "status": "error",
                "error": str(e),
                "exit_code": -1
            }
    
    def destroy_session(self, session_id: str) -> bool:
        """
        Destroy a session and cleanup resources.
        
        Args:
            session_id: Session identifier
        
        Returns:
            True if destroyed successfully
        """
        with self._lock:
            return self._destroy_session_unlocked(session_id)
    
    def _destroy_session_unlocked(self, session_id: str) -> bool:
        """Internal method to destroy session (must hold lock)."""
        session = self.sessions.get(session_id)
        
        if not session:
            return False
        
        try:
            session.is_active = False
            session.sandbox.destroy()
            del self.sessions[session_id]
            self.metrics["sessions_destroyed"] += 1
            
            logger.info(f"Session destroyed: {session_id}")
            return True
            
        except Exception as e:
            logger.error(f"Error destroying session {session_id}: {e}")
            self.metrics["errors"] += 1
            return False
    
    def list_sessions(self) -> List[Dict[str, Any]]:
        """
        List all active sessions.
        
        Returns:
            List of session info dictionaries
        """
        with self._lock:
            return [
                {
                    "id": s.id,
                    "template": s.template,
                    "age": round(s.age, 2),
                    "idle_time": round(s.idle_time, 2),
                    "ttl": s.ttl,
                    "is_expired": s.is_expired,
                    "use_count": s.use_count,
                    "metadata": s.metadata
                }
                for s in self.sessions.values()
                if s.is_active
            ]
    
    def get_metrics(self) -> Dict[str, Any]:
        """Get session manager metrics."""
        with self._lock:
            return {
                **self.metrics,
                "active_sessions": len(self.sessions),
                "max_sessions": self.max_sessions,
                "default_ttl": self.default_ttl
            }
    
    def _cleanup_expired(self):
        """Clean up expired sessions."""
        expired_ids = [
            sid for sid, session in self.sessions.items()
            if session.is_expired
        ]
        
        for sid in expired_ids:
            self._destroy_session_unlocked(sid)
            self.metrics["sessions_expired"] += 1
        
        if expired_ids:
            logger.info(f"Cleaned up {len(expired_ids)} expired sessions")
    
    def _start_cleanup_thread(self):
        """Start background cleanup thread."""
        def cleanup_loop():
            while not self._stop_cleanup.wait(self.cleanup_interval):
                try:
                    with self._lock:
                        self._cleanup_expired()
                except Exception as e:
                    logger.error(f"Cleanup thread error: {e}")
        
        self._cleanup_thread = threading.Thread(
            target=cleanup_loop,
            name="SessionCleanup",
            daemon=True
        )
        self._cleanup_thread.start()
        logger.info("Session cleanup thread started")
    
    def stop(self):
        """Stop session manager and cleanup all resources."""
        logger.info("Stopping session manager")
        
        # Signal cleanup thread to stop
        self._stop_cleanup.set()
        
        if self._cleanup_thread:
            self._cleanup_thread.join(timeout=5)
        
        # Destroy all sessions
        with self._lock:
            session_ids = list(self.sessions.keys())
            for sid in session_ids:
                self._destroy_session_unlocked(sid)
        
        logger.info("Session manager stopped")
    
    def __enter__(self):
        """Context manager entry."""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.stop()


class SessionPool:
    """
    Pre-warmed pool of sandbox sessions for faster execution.
    
    Useful for high-throughput scenarios where session creation
    overhead needs to be minimized.
    """
    
    def __init__(
        self,
        manager: SessionManager,
        template: str = "default",
        min_size: int = 2,
        max_size: int = 5,
        **sandbox_kwargs
    ):
        """
        Initialize session pool.
        
        Args:
            manager: SessionManager instance
            template: Template name for pooled sessions
            min_size: Minimum number of pre-warmed sessions
            max_size: Maximum pool size
            **sandbox_kwargs: Additional sandbox configuration
        """
        self.manager = manager
        self.template = template
        self.min_size = min_size
        self.max_size = max_size
        self.sandbox_kwargs = sandbox_kwargs
        
        self._pool: List[str] = []
        self._lock = threading.RLock()
        
        # Pre-warm pool
        self._initialize_pool()
    
    def _initialize_pool(self):
        """Create initial pool of sessions."""
        for _ in range(self.min_size):
            try:
                sid = self.manager.create_session(
                    template=self.template,
                    **self.sandbox_kwargs
                )
                self._pool.append(sid)
            except Exception as e:
                logger.error(f"Failed to initialize pool session: {e}")
    
    def acquire(self) -> Optional[str]:
        """
        Acquire a session from the pool.
        
        Returns:
            Session ID or None if pool exhausted
        """
        with self._lock:
            # Try to get from pool
            while self._pool:
                sid = self._pool.pop(0)
                session = self.manager.get_session(sid)
                if session:
                    return sid
            
            # Pool empty, create new if under max_size
            if len(self._pool) < self.max_size:
                try:
                    return self.manager.create_session(
                        template=self.template,
                        **self.sandbox_kwargs
                    )
                except Exception as e:
                    logger.error(f"Failed to create session: {e}")
            
            return None
    
    def release(self, session_id: str, destroy: bool = False):
        """
        Return a session to the pool or destroy it.
        
        Args:
            session_id: Session to release
            destroy: If True, destroy instead of returning to pool
        """
        if destroy:
            self.manager.destroy_session(session_id)
            return
        
        with self._lock:
            session = self.manager.get_session(session_id)
            if session and len(self._pool) < self.max_size:
                self._pool.append(session_id)
            else:
                self.manager.destroy_session(session_id)
    
    def __enter__(self) -> Optional[str]:
        """Context manager entry - acquire session."""
        return self.acquire()
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - release session."""
        # Note: Session ID must be stored externally for this to work
        pass

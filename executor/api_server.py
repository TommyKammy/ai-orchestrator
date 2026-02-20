"""
Executor API Server for n8n integration
Phase 2: Sandbox Integration

Provides HTTP API for sandbox execution that can be called from n8n.
"""

import json
import logging
import os
from typing import Dict, Any, Optional
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
import threading

# Import our sandbox modules
from executor.sandbox import CodeSandbox
from executor.session import SessionManager
from executor.filesystem import FileSystemManager
from executor.templates import template_manager

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Global session manager
session_manager = SessionManager(
    default_ttl=300,
    max_sessions=10,
    enable_cleanup_thread=True
)


class ExecutorHandler(BaseHTTPRequestHandler):
    """HTTP request handler for executor API."""
    
    def log_message(self, format, *args):
        """Override to use our logger."""
        logger.info(f"{self.address_string()} - {format % args}")
    
    def _send_json_response(self, data: Dict[str, Any], status: int = 200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))
    
    def _send_error(self, message: str, status: int = 400):
        """Send error response."""
        self._send_json_response({"status": "error", "error": message}, status)
    
    def _read_body(self) -> Dict[str, Any]:
        """Read and parse request body."""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        
        body = self.rfile.read(content_length).decode('utf-8')
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}
    
    def do_GET(self):
        """Handle GET requests."""
        parsed = urlparse(self.path)
        path = parsed.path
        
        if path == '/health':
            self._send_json_response({
                "status": "healthy",
                "service": "executor-api",
                "version": "2.0.0"
            })
        
        elif path == '/templates':
            templates = template_manager.list_templates()
            self._send_json_response({
                "status": "success",
                "templates": templates
            })
        
        elif path == '/sessions':
            sessions = session_manager.list_sessions()
            self._send_json_response({
                "status": "success",
                "sessions": sessions
            })
        
        elif path == '/metrics':
            metrics = session_manager.get_metrics()
            self._send_json_response({
                "status": "success",
                "metrics": metrics
            })
        
        else:
            self._send_error("Not found", 404)
    
    def do_POST(self):
        """Handle POST requests."""
        parsed = urlparse(self.path)
        path = parsed.path
        body = self._read_body()
        
        try:
            if path == '/execute':
                self._handle_execute(body)
            elif path == '/session/create':
                self._handle_create_session(body)
            elif path == '/session/destroy':
                self._handle_destroy_session(body)
            elif path == '/session/execute':
                self._handle_session_execute(body)
            else:
                self._send_error("Not found", 404)
        except Exception as e:
            logger.error(f"Request failed: {e}")
            self._send_error(f"Internal error: {str(e)}", 500)
    
    def _handle_execute(self, body: Dict[str, Any]):
        """Handle direct code execution."""
        tenant_id = body.get('tenant_id')
        scope = body.get('scope')
        code = body.get('code')
        language = body.get('language', 'python')
        template = body.get('template', 'default')
        files = body.get('files', {})
        
        if not all([tenant_id, scope, code]):
            self._send_error("Missing required fields: tenant_id, scope, code")
            return
        
        code = str(code)  # Ensure code is string
        
        # Get template configuration
        template_kwargs = template_manager.get_sandbox_kwargs(template)
        
        try:
            with CodeSandbox(**template_kwargs) as sandbox:
                # Upload files if provided
                if files:
                    for path, content in files.items():
                        sandbox.write_file(path, content)
                
                # Execute code
                result = sandbox.run_code(code, language)
                
                response = {
                    "status": "success" if result['exit_code'] == 0 else "error",
                    "tenant_id": tenant_id,
                    "scope": scope,
                    "result": result
                }
                
                self._send_json_response(response)
                
        except Exception as e:
            logger.error(f"Execution failed: {e}")
            self._send_json_response({
                "status": "error",
                "tenant_id": tenant_id,
                "scope": scope,
                "error": str(e)
            })
    
    def _handle_create_session(self, body: Dict[str, Any]):
        """Handle session creation."""
        tenant_id = body.get('tenant_id')
        scope = body.get('scope')
        template = body.get('template', 'default')
        ttl = body.get('ttl', 300)
        
        if not all([tenant_id, scope]):
            self._send_error("Missing required fields: tenant_id, scope")
            return
        
        try:
            # Get template configuration
            template_kwargs = template_manager.get_sandbox_kwargs(template)
            
            # Create session
            session_id = session_manager.create_session(
                template=template,
                ttl=ttl,
                metadata={
                    "tenant_id": tenant_id,
                    "scope": scope
                },
                **template_kwargs
            )
            
            self._send_json_response({
                "status": "success",
                "session_id": session_id,
                "template": template,
                "ttl": ttl
            })
            
        except Exception as e:
            logger.error(f"Session creation failed: {e}")
            self._send_error(str(e))
    
    def _handle_destroy_session(self, body: Dict[str, Any]):
        """Handle session destruction."""
        session_id = body.get('session_id')
        
        if not session_id:
            self._send_error("Missing required field: session_id")
            return
        
        success = session_manager.destroy_session(session_id)
        
        if success:
            self._send_json_response({
                "status": "success",
                "message": f"Session {session_id} destroyed"
            })
        else:
            self._send_error(f"Session {session_id} not found", 404)
    
    def _handle_session_execute(self, body: Dict[str, Any]):
        """Handle execution in existing session."""
        session_id = body.get('session_id')
        code = body.get('code')
        language = body.get('language', 'python')
        files = body.get('files', {})
        
        if not all([session_id, code]):
            self._send_error("Missing required fields: session_id, code")
            return
        
        result = session_manager.execute_in_session(
            session_id, code, language, files
        )
        
        self._send_json_response(result)


def start_server(host: str = '0.0.0.0', port: int = 8080):
    """
    Start the executor API server.
    
    Args:
        host: Host to bind to
        port: Port to listen on
    """
    server = HTTPServer((host, port), ExecutorHandler)
    logger.info(f"Executor API server started on {host}:{port}")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down server...")
        session_manager.stop()
        server.shutdown()


if __name__ == "__main__":
    # Get port from environment or use default
    port = int(os.environ.get('EXECUTOR_PORT', 8080))
    start_server(port=port)
